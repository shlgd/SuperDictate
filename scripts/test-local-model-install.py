"""Opt-in clean network installation smoke test; never changes installed models."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--python", required=True)
parser.add_argument("--timeout", type=float, default=600)
args = parser.parse_args()
script = Path(__file__).resolve().parents[1] / "swift/Resources/local-asr.py"
with tempfile.TemporaryDirectory(prefix="superdictate-clean-install-") as directory:
    root = Path(directory)
    env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(root), LANG="en_US.UTF-8",
               PIP_CONFIG_FILE="/dev/null", PIP_NO_INPUT="1", PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1",
               HF_HUB_DISABLE_IMPLICIT_TOKEN="1", PIP_NO_CACHE_DIR="1",
               HF_HOME=str(root / "hf"), XDG_CACHE_HOME=str(root / "cache"), TMPDIR=directory)
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    started = time.monotonic()
    process = subprocess.Popen([args.python, "-I", "-B", "-u", str(script), "install", "--root", directory,
                                "--model", "whisper_turbo"], env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        output, errors = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, errors = process.communicate()
        print(output[-8000:])
        print(errors[-8000:])
        raise RuntimeError("Clean installation exceeded smoke-test deadline")
    if process.returncode:
        print(output[-8000:])
        print(errors[-8000:])
        raise RuntimeError(f"Clean installation failed: exit {process.returncode}")
    messages = [json.loads(line) for line in output.splitlines()]
    assert not any(message.get("error") for message in messages)
    phases = list(dict.fromkeys(message.get("phase") for message in messages))
    assert "ready" in phases, phases
    model = root / "models/whisper_turbo"
    manifest = json.loads((model / "ready.json").read_text())
    assert all((model / entry["name"]).stat().st_size == entry["size"] for entry in manifest["files"])
    print(f"PASS clean Whisper Turbo installation in {time.monotonic() - started:.1f}s")
    print("Phases:", phases)
    print("Verified model bytes:", sum(entry["size"] for entry in manifest["files"]))
