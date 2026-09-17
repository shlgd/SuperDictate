"""No model weights, microphone access or inference. Run with a numpy-enabled Python."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
import ssl
import threading
import urllib.error
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "swift/Resources/local-asr.py"
spec = importlib.util.spec_from_file_location("local_asr", SCRIPT)
asr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asr)


class RuntimeTests(unittest.TestCase):
    def test_setup_process_reports_stage(self):
        with patch.object(asr, "emit") as progress:
            asr.checked_run([sys.executable, "-c", "pass"], phase="runtime-imports", timeout=5)
        progress.assert_called_with(phase="runtime-imports")
        self.assertIsNone(asr.child)

    def test_setup_timeout_kills_child(self):
        with patch.object(asr, "emit"):
            with self.assertRaisesRegex(RuntimeError, "timed out during runtime-packages"):
                asr.checked_run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=.05)
        self.assertIsNone(asr.child)

    def test_setup_failure_is_reported(self):
        with patch.object(asr, "emit"):
            with self.assertRaisesRegex(RuntimeError, "exit 7"):
                asr.checked_run([sys.executable, "-c", "raise SystemExit(7)"], timeout=5)
        self.assertIsNone(asr.child)

    def test_catalog_is_bounded_and_pinned(self):
        self.assertEqual(len(asr.CATALOG), 5)
        self.assertEqual(set(asr.REVISIONS), set(asr.CATALOG) - {"gigaam_v3"})
        self.assertTrue(all(len(value) == 40 for value in asr.REVISIONS.values()))

    def test_atomic_manifest_and_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / "models/whisper_turbo"
            model.mkdir(parents=True)
            (model / "weights").write_bytes(b"1234")
            manifest = dict(version="1", key="whisper_turbo", files=[dict(name="weights", size=4)])
            asr.atomic_json(model / "ready.json", manifest)
            self.assertEqual(asr.validate_install(root, "whisper_turbo"), model)
            (model / "weights").write_bytes(b"12")
            with self.assertRaisesRegex(RuntimeError, "Incomplete"):
                asr.validate_install(root, "whisper_turbo")

    def test_invalid_manifest_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / "models/whisper_turbo"
            model.mkdir(parents=True)
            asr.atomic_json(model / "ready.json", dict(version="1", key="whisper_turbo",
                            files=[dict(name="../escape", size=4)]))
            with self.assertRaisesRegex(RuntimeError, "Invalid"):
                asr.validate_install(root, "whisper_turbo")

    def test_download_verifies_and_reuses_cache(self):
        payload = b"small test model"
        sha = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as directory, patch.object(asr, "emit"):
            path = Path(directory) / "weights"
            with patch.object(asr.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as network:
                self.assertEqual(asr.fetch("https://example.test/model", path, 0, len(payload), 0, len(payload), sha), len(payload))
                network.assert_called_once()
            with patch.object(asr.urllib.request, "urlopen") as network:
                asr.fetch("https://example.test/model", path, 0, len(payload), 0, len(payload), sha)
                network.assert_not_called()

    def test_download_failure_never_creates_final_file(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(asr, "emit"), patch.object(asr.time, "sleep"):
            path = Path(directory) / "weights"
            with patch.object(asr.urllib.request, "urlopen", side_effect=lambda *a, **kw: io.BytesIO(b"bad")):
                with self.assertRaisesRegex(RuntimeError, "checksum"):
                    asr.fetch("https://example.test/model", path, 0, 3, 0, 3, "wrong")
            self.assertFalse(path.exists())
            self.assertFalse(path.with_suffix(".part").exists())

    def test_runtime_failure_removes_staging(self):
        def fake_setup(arguments, **kwargs):
            if "venv" in arguments:
                path = Path(arguments[-1])
                path.mkdir()
                (path / "partial").write_bytes(b"unfinished")
                return
            raise RuntimeError("network error")
        with tempfile.TemporaryDirectory() as directory, patch.object(asr, "emit"):
            root = Path(directory)
            with patch.object(asr, "checked_run", side_effect=fake_setup):
                with self.assertRaisesRegex(RuntimeError, "network error"):
                    asr.bootstrap(root, "qwen_06")
            self.assertFalse((root / ".runtime-stage").exists())
            self.assertFalse((root / "runtime-v2").exists())

    def test_native_packages_cannot_fall_back_to_compilation(self):
        calls = []
        def setup(arguments, **kwargs):
            calls.append(arguments)
            if "venv" in arguments:
                Path(arguments[-1]).mkdir()
        with tempfile.TemporaryDirectory() as directory, patch.object(asr, "emit"):
            with patch.object(asr, "checked_run", side_effect=setup):
                asr.bootstrap(Path(directory), "whisper_turbo")
        pip = next(command for command in calls if "pip" in command)
        self.assertIn("--only-binary=:all:", pip)
        self.assertIn("--no-binary=gigaam,antlr4-python3-runtime", pip)

    def test_manifest_timeout_retries_then_recovers(self):
        import httpx
        sentinel = object()
        with patch("huggingface_hub.HfApi") as api, patch.object(asr, "emit") as progress, patch.object(asr.time, "sleep"):
            api.return_value.model_info.side_effect = [httpx.ReadTimeout("private details"), sentinel]
            self.assertIs(asr.model_info("test/model", "revision"), sentinel)
            api.assert_called_once_with(endpoint="https://huggingface.co", token=False)
            self.assertEqual(api.return_value.model_info.call_count, 2)
            self.assertEqual(api.return_value.model_info.call_args.kwargs["timeout"], 30)
            self.assertFalse(api.return_value.model_info.call_args.kwargs["token"])
            progress.assert_called_once_with(phase="listing", retry=1, failure_code="timeout", code=1)

    def test_manifest_failure_is_bounded_and_safe(self):
        import httpx
        with patch("huggingface_hub.HfApi") as api, patch.object(asr, "emit"), patch.object(asr.time, "sleep"):
            api.return_value.model_info.side_effect = httpx.ConnectTimeout("SECRET /Users/private")
            with self.assertRaises(asr.SetupFailure) as result:
                asr.model_info("test/model", "revision")
            self.assertEqual(api.return_value.model_info.call_count, 3)
            self.assertEqual(asr.failure_details(result.exception), ("timeout", 1))
            self.assertNotIn("SECRET", str(result.exception))

    def test_manifest_auth_error_is_not_retried(self):
        import httpx
        response = httpx.Response(403, request=httpx.Request("GET", "https://example.test"))
        with patch("huggingface_hub.HfApi") as api, patch.object(asr.time, "sleep") as sleep:
            api.return_value.model_info.side_effect = httpx.HTTPStatusError("forbidden", request=response.request, response=response)
            with self.assertRaises(asr.SetupFailure) as result:
                asr.model_info("test/model", "revision")
            self.assertEqual(asr.failure_details(result.exception), ("http", 403))
            self.assertEqual(api.return_value.model_info.call_count, 1)
            sleep.assert_not_called()

    def test_manifest_real_http_failure_then_retry(self):
        from huggingface_hub import HfApi
        class Handler(BaseHTTPRequestHandler):
            calls = 0
            def do_GET(self):
                Handler.calls += 1
                if Handler.calls == 1:
                    self.send_response(503)
                    self.end_headers()
                    return
                body = json.dumps(dict(id="test/model", sha="revision", siblings=[])).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            api = HfApi(endpoint=f"http://127.0.0.1:{server.server_port}", token=False)
            with patch("huggingface_hub.HfApi", return_value=api), patch.object(asr, "emit") as progress, patch.object(asr.time, "sleep"):
                self.assertEqual(asr.model_info("test/model", "revision").sha, "revision")
                self.assertEqual(Handler.calls, 2)
                progress.assert_called_once_with(phase="listing", retry=1, failure_code="http", code=503)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_runtime_is_shared_and_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = root / "runtime-v2"
            environment.mkdir()
            (environment / "runtime-version").write_text("2")
            with patch.object(asr, "checked_run") as install:
                for key in asr.CATALOG:
                    self.assertEqual(asr.bootstrap(root, key), environment / "bin/python3")
                self.assertEqual(install.call_count, len(asr.CATALOG))
                self.assertTrue(all(call.kwargs["phase"] == "runtime-imports" for call in install.call_args_list))
                self.assertTrue(all("-I" in call.args[0] for call in install.call_args_list))

    def test_broken_runtime_is_rebuilt(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(asr, "emit") as progress:
            root = Path(directory)
            old = root / "runtime-v2"
            old.mkdir()
            (old / "runtime-version").write_text("2")
            (old / "broken").touch()
            def setup(arguments, **kwargs):
                if str(old / "bin/python3") == arguments[0]:
                    raise asr.SetupFailure("missing module", "imports")
                if "venv" in arguments:
                    Path(arguments[-1]).mkdir()
            with patch.object(asr, "checked_run", side_effect=setup):
                asr.bootstrap(root, "whisper_turbo")
            self.assertFalse((old / "broken").exists())
            self.assertEqual((old / "runtime-version").read_text(), "2")
            self.assertIn(unittest.mock.call(phase="runtime-repair"), progress.call_args_list)

    def test_failure_categories_do_not_include_private_details(self):
        secret = "private transcript /Users/private/person hf_secret https://private.example/key"
        self.assertEqual(asr.failure_details(RuntimeError(secret)), ("unknown", 1))
        self.assertEqual(asr.failure_details(urllib.error.HTTPError(secret, 403, secret, {}, None)), ("http", 403))
        self.assertEqual(asr.failure_details(urllib.error.URLError(ssl.SSLError(secret))), ("tls", 1))

    def test_segmentation_preserves_every_sample(self):
        import numpy as np
        audio = np.arange(16000 * 63, dtype=np.float32)
        segments = list(asr.chunks(audio))
        self.assertGreater(len(segments), 1)
        np.testing.assert_array_equal(np.concatenate([part for part, _ in segments]), audio)
        self.assertTrue(all(len(part) <= 24 * 16000 for part, _ in segments))
        self.assertEqual(segments[-1][1], 1)
        self.assertEqual(list(asr.chunks(np.zeros(0, dtype=np.float32))), [])

    def test_protocol_is_one_json_line(self):
        output = io.StringIO()
        with patch.object(asr, "PROTOCOL", output):
            asr.emit(text="строка\nещё строка")
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        self.assertEqual(json.loads(output.getvalue())["text"], "строка\nещё строка")


if __name__ == "__main__":
    unittest.main()
