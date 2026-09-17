"""No model weights, microphone access or inference. Run with a numpy-enabled Python."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
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

    def test_runtime_is_shared_and_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = root / "runtime-v2"
            environment.mkdir()
            (environment / "runtime-version").write_text("2")
            with patch.object(asr, "checked_run") as install:
                for key in asr.CATALOG:
                    self.assertEqual(asr.bootstrap(root, key), environment / "bin/python3")
                install.assert_not_called()

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
