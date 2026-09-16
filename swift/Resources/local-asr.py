"""Optional local ASR runtime. No audio leaves this process or this computer."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import venv

CATALOG = {
    "whisper_large_v3": ("whisper", "mlx-community/whisper-large-v3-mlx"),
    "whisper_turbo": ("whisper", "mlx-community/whisper-large-v3-turbo"),
    "qwen_06": ("qwen", "mlx-community/Qwen3-ASR-0.6B-8bit"),
    "qwen_17": ("qwen", "mlx-community/Qwen3-ASR-1.7B-8bit"),
    "gigaam_v3": ("gigaam", "v3_e2e_rnnt"),
}
REVISIONS = {
    "whisper_large_v3": "49e6aa286ad60c14352c404340ded53710378a11",
    "whisper_turbo": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
    "qwen_06": "89e96d92ba34aca20b3e29fb10cc284097d1219f",
    "qwen_17": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
}
GIGA_REVISION = "7447938d791c4f3e643386ee22c33777004293a5"
RUNTIME_VERSION = "1"
PROTOCOL = sys.stdout
child = None


def emit(**values):
    PROTOCOL.write(json.dumps(values, ensure_ascii=False) + "\n")
    PROTOCOL.flush()


def atomic_json(path, values):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(values))
    temporary.replace(path)


def watch_parent():
    parent = os.getppid()
    while True:
        time.sleep(1)
        if os.getppid() != parent:
            if child is not None and child.poll() is None:
                child.kill()
            os._exit(1)


def checked_run(arguments):
    global child
    child = subprocess.Popen(arguments, stdout=sys.stderr, stderr=sys.stderr)
    try:
        code = child.wait(timeout=1200)
        if code:
            raise RuntimeError(f"Runtime setup failed (exit {code}). See local-models.log.")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        child = None


def bootstrap(root, key):
    if sys.version_info < (3, 11):
        raise RuntimeError("Experimental models require Python 3.11 or newer.")
    engine, _ = CATALOG[key]
    environment = root / ("runtime-giga" if engine == "gigaam" else "runtime-mlx")
    marker = environment / "runtime-version"
    if marker.exists() and marker.read_text() == RUNTIME_VERSION:
        return environment / "bin/python3"
    emit(phase="runtime")
    venv.EnvBuilder(with_pip=True).create(environment)
    python = environment / "bin/python3"
    packages = (["mlx-audio[stt]==0.5.4", "mlx-whisper==0.4.3"] if engine != "gigaam" else [
        f"gigaam[torch] @ https://github.com/salute-developers/GigaAM/archive/{GIGA_REVISION}.zip",
        "torch==2.14.0", "torchaudio==2.14.0",
    ])
    checked_run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir", *packages])
    marker.write_text(RUNTIME_VERSION)
    return python


def file_digest(path, algorithm="sha256"):
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def fetch(url, path, completed, total, started, expected_size=None, sha=None, transfer=None):
    if transfer is None:
        transfer = {"bytes": 0, "started": time.monotonic()}
    if path.exists() and (expected_size is None or path.stat().st_size == expected_size):
        if sha is None or file_digest(path) == sha:
            return path.stat().st_size
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".part")
    # The partial is never advertised as a usable model. A retry starts this file over.
    for attempt in range(3):
        downloaded = 0
        try:
            with urllib.request.urlopen(url, timeout=30) as response, partial.open("wb") as output:
                last = 0.0
                while True:
                    data = response.read(1024 * 1024)
                    if not data:
                        break
                    output.write(data)
                    downloaded += len(data)
                    transfer["bytes"] += len(data)
                    now = time.monotonic()
                    if now - last >= .2:
                        elapsed = max(now - transfer["started"], .001)
                        emit(phase="downloading", downloaded=completed + downloaded, total=total,
                             speed=transfer["bytes"] / elapsed)
                        last = now
            if expected_size is not None and downloaded != expected_size:
                raise RuntimeError("Incomplete model download")
            if sha and file_digest(partial) != sha:
                raise RuntimeError("Model checksum mismatch")
            partial.replace(path)
            return downloaded
        except Exception:
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def download(root, key):
    engine, repo = CATALOG[key]
    destination = root / "models" / key
    destination.mkdir(parents=True, exist_ok=True)
    ready = destination / "ready.json"
    ready.unlink(missing_ok=True)
    emit(phase="listing")
    if engine == "gigaam":
        base = "https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM"
        names = [repo + ".ckpt", repo + "_tokenizer.model"]
        files = []
        for name in names:
            url = f"{base}/{name}"
            with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30) as response:
                size = int(response.headers["Content-Length"])
            files.append((name, size, None, url))
        revision = GIGA_REVISION
    else:
        from huggingface_hub import HfApi
        info = HfApi().model_info(repo, revision=REVISIONS[key], files_metadata=True)
        revision = info.sha
        files = []
        for entry in info.siblings:
            if not entry.rfilename.endswith((".json", ".safetensors", ".npz", ".model", ".txt", ".tiktoken")):
                continue
            if "/" in entry.rfilename:
                continue
            sha = entry.lfs.sha256 if entry.lfs else None
            files.append((entry.rfilename, entry.size, sha,
                          f"https://huggingface.co/{repo}/resolve/{revision}/{entry.rfilename}"))
    if not files:
        raise RuntimeError("Model manifest is empty")
    total = sum(entry[1] for entry in files)
    if shutil.disk_usage(root).free < total + 2 * 1024 ** 3:
        raise RuntimeError("Not enough free disk space: model size plus 2 GB required.")
    completed = 0
    started = time.monotonic()
    transfer = {"bytes": 0, "started": started}
    for name, size, sha, url in files:
        completed += fetch(url, destination / name, completed, total, started, size, sha, transfer)
        emit(phase="downloading", downloaded=completed, total=total,
             speed=transfer["bytes"] / max(time.monotonic() - started, .001))
    emit(phase="verifying")
    if engine == "gigaam":
        import gigaam
        if file_digest(destination / (repo + ".ckpt"), "md5") != gigaam._MODEL_HASHES[repo]:
            raise RuntimeError("GigaAM checksum mismatch")
    # Import validation is deliberately not inference or a model warm-up.
    if engine == "whisper":
        import mlx_whisper
    elif engine == "qwen":
        from mlx_audio.stt import load
    manifest = dict(version=RUNTIME_VERSION, key=key, revision=revision,
                    files=[dict(name=n, size=s) for n, s, _, _ in files])
    atomic_json(ready, manifest)
    emit(phase="ready", downloaded=total, total=total)


def validate_install(root, key):
    destination = root / "models" / key
    marker = json.loads((destination / "ready.json").read_text())
    if marker.get("version") != RUNTIME_VERSION or marker.get("key") != key:
        raise RuntimeError("Model needs to be downloaded again")
    for entry in marker["files"]:
        if Path(entry["name"]).name != entry["name"] or entry["size"] <= 0:
            raise RuntimeError("Invalid local model manifest")
        if (destination / entry["name"]).stat().st_size != entry["size"]:
            raise RuntimeError("Incomplete local model. Download it again in Settings.")
    return destination


def chunks(audio, sample_rate=16000):
    """Bound memory and GigaAM's 25-second limit; cut at the quietest nearby frame."""
    import numpy as np
    start = 0
    while len(audio) - start > 24 * sample_rate:
        left = start + 20 * sample_rate
        region = audio[left:start + 24 * sample_rate]
        frames = region[:len(region) // 320 * 320].reshape(-1, 320)
        end = left + int(np.argmin(np.mean(frames ** 2, axis=1))) * 320 + 160
        yield audio[start:end], end / len(audio)
        start = end
    if start < len(audio):
        yield audio[start:], 1.0


def serve(root, key):
    import numpy as np
    directory = validate_install(root, key)
    engine, name = CATALOG[key]
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    if engine == "whisper":
        import mlx_whisper
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder
        ModelHolder.get_model(str(directory), mx.float16)
        def transcribe(audio, language):
            return mlx_whisper.transcribe(audio, path_or_hf_repo=str(directory), language=language,
                                          temperature=0, verbose=None)["text"]
    elif engine == "qwen":
        from mlx_audio.stt import load
        model = load(str(directory))
        languages = {"ru": "Russian", "en": "English", "fr": "French", "de": "German",
                     "es": "Spanish", "it": "Italian", "pt": "Portuguese"}
        def transcribe(audio, language):
            # Unsupported language hints fall back to the model's auto-detection.
            return model.generate(audio, language=languages.get(language), max_tokens=1024).text
    else:
        import gigaam
        import torch
        torch.set_num_threads(4)
        model = gigaam.load_model(name, device="cpu", download_root=str(directory))
        def transcribe(audio, language):
            if language not in (None, "ru"):
                raise RuntimeError("GigaAM v3 supports Russian; choose Auto or Russian.")
            with torch.inference_mode():
                wav = torch.from_numpy(audio.copy()).unsqueeze(0)
                lengths = torch.tensor([wav.shape[-1]])
                encoded, encoded_lengths = model(wav, lengths)
                return model._decode(encoded, encoded_lengths, lengths)[0][0]
    emit(ready=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            audio = np.fromfile(request["path"], dtype="<f4")
            if not len(audio):
                emit(text="")
                continue
            pieces = []
            for segment, fraction in chunks(audio):
                pieces.append(transcribe(segment, request.get("language")))
                emit(progress=fraction)
            emit(text=" ".join(p.strip() for p in pieces if p.strip()))
        except Exception as error:
            emit(error=str(error))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["install", "download", "serve"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--model", choices=CATALOG, required=True)
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    def cancel(signum, frame):
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        sys.exit(1)
    signal.signal(signal.SIGTERM, cancel)
    threading.Thread(target=watch_parent, daemon=True).start()
    with contextlib.redirect_stdout(sys.stderr):
        if args.command == "install":
            python = bootstrap(args.root, args.model)
            os.execv(str(python), [str(python), "-u", __file__, "download", "--root", str(args.root), "--model", args.model])
        elif args.command == "download":
            download(args.root, args.model)
        else:
            serve(args.root, args.model)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit(error=str(error))
        sys.exit(1)
