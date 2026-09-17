"""Opt-in clean network installation smoke test; never changes installed models."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--python", required=True)
parser.add_argument("--timeout", type=float, default=600)
parser.add_argument("--prepare-only", action="store_true", help="Check dependencies without downloading model weights")
args = parser.parse_args()
script = Path(__file__).resolve().parents[1] / "swift/Resources/local-asr.py"
with tempfile.TemporaryDirectory(prefix="superdictate-clean-install-") as directory:
    root = Path(directory)
    tools = root / "unavailable-tools"
    tools.mkdir()
    trap = tools / "blocked"
    trap.write_bytes((script.parents[2] / "scripts/forbidden-build-tool.sh").read_bytes())
    trap.chmod(0o700)
    for name in ("cc", "c++", "clang", "clang++", "gcc", "g++", "rustc", "cargo", "cmake", "make", "git", "xcrun", "xcodebuild", "brew"):
        (tools / name).symlink_to(trap)
    env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(root), LANG="en_US.UTF-8",
               PIP_CONFIG_FILE="/dev/null", PIP_NO_INPUT="1", PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1",
               HF_HUB_DISABLE_IMPLICIT_TOKEN="1", PIP_NO_CACHE_DIR="1",
               HF_HOME=str(root / "hf"), XDG_CACHE_HOME=str(root / "cache"), TMPDIR=directory)
    env.update(PATH=str(tools) + ":" + env["PATH"], CC=str(trap), CXX=str(trap),
               RUSTC=str(trap), CMAKE=str(trap), DEVELOPER_DIR=str(root / "no-xcode"),
               SUPERDICTATE_BUILD_TOOL_PROBE=str(root / "build-tool-used"))
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    started = time.monotonic()
    command = "prepare" if args.prepare_only else "install"
    process = subprocess.Popen([args.python, "-I", "-B", "-u", str(script), command, "--root", directory,
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
    probe = root / "build-tool-used"
    if probe.exists():
        probes = probe.read_text().splitlines()
        # pip probes rustc solely for its User-Agent and tolerates its absence.
        # The trap still fails that probe; actual compilation remains forbidden.
        unexpected = [line for line in probes if line != "rustc --version"]
        print("Blocked optional rustc version probes:", len(probes) - len(unexpected))
        assert not unexpected, f"Installation attempted to use development tools: {unexpected}"
    assert not any(message.get("error") for message in messages)
    phases = list(dict.fromkeys(message.get("phase") for message in messages))
    assert ("runtime-ready" if args.prepare_only else "ready") in phases, phases
    if args.prepare_only:
        print(f"PASS clean dependencies without development tools in {time.monotonic() - started:.1f}s")
        print("Phases:", phases)
        sys.exit(0)
    model = root / "models/whisper_turbo"
    manifest = json.loads((model / "ready.json").read_text())
    assert all((model / entry["name"]).stat().st_size == entry["size"] for entry in manifest["files"])
    print(f"PASS clean Whisper Turbo installation in {time.monotonic() - started:.1f}s")
    print("Phases:", phases)
    print("Verified model bytes:", sum(entry["size"] for entry in manifest["files"]))
    print("PASS installation succeeded with development tools unavailable")
