"""Publisher-only builder. Customers receive this complete, relocatable runtime."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PYTHON_URL = "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.11.16%2B20260901-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_SHA = "50424fa409e8ae84b82a3052522f64695b47dff2158b70bb7358e0ebd6c085c9"
GIGA = "https://github.com/salute-developers/GigaAM/archive/7447938d791c4f3e643386ee22c33777004293a5.zip"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def public_metadata(item):
    item.uid = item.gid = 0
    item.uname = item.gname = "root"
    item.mtime = 0
    item.pax_headers = {}
    item.mode &= 0o755
    return item


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "dist/speech-runtime")
    parser.add_argument("--normalize-existing", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.normalize_existing:
        output = args.output / "SuperDictate-SpeechRuntime.tar.gz"
        pending = output.with_suffix(".pending")
        with tarfile.open(output) as source, tarfile.open(pending, "w:gz") as target:
            for item in source:
                target.addfile(public_metadata(item), source.extractfile(item) if item.isfile() else None)
        pending.replace(output)
        path = args.output / "speech-runtime.json"
        manifest = json.loads(path.read_text())
        manifest.update(sha256=digest(output), bytes=output.stat().st_size,
                        url="https://github.com/shlgd/SuperDictate/releases/download/v0.2.48/SuperDictate-SpeechRuntime.tar.gz")
        path.write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(manifest), flush=True)
        return
    archive = args.output / "cpython.tar.gz"
    if not archive.exists() or digest(archive) != PYTHON_SHA:
        print("Downloading pinned publisher Python", flush=True)
        with urllib.request.urlopen(PYTHON_URL, timeout=30) as source, archive.open("wb") as target:
            shutil.copyfileobj(source, target)
    if digest(archive) != PYTHON_SHA:
        raise RuntimeError("Publisher Python checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="speech-runtime-build-") as temporary:
        work = Path(temporary)
        with tarfile.open(archive) as source:
            source.extractall(work, filter="data")
        runtime = work / "runtime"
        (work / "python").rename(runtime)
        python = runtime / "bin/python3"
        env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(work), TMPDIR=str(work),
                   LANG="en_US.UTF-8", PIP_CONFIG_FILE="/dev/null", PIP_NO_CACHE_DIR="1",
                   PYTHONDONTWRITEBYTECODE="1", HF_HOME=str(work / "hf"))
        def run(*arguments):
            subprocess.run([str(python), "-I", "-B", *arguments], env=env, check=True, timeout=1200)
        wheels = work / "wheels"
        wheels.mkdir()
        run("-m", "pip", "wheel", "--no-deps", "--wheel-dir", str(wheels),
            "--index-url", "https://pypi.org/simple", "--timeout", "20", "--retries", "2",
            f"gigaam @ {GIGA}", "antlr4-python3-runtime==4.9.3")
        site = runtime / "lib/python3.11/site-packages"
        run("-m", "pip", "install", "--target", str(site), "--upgrade", "--no-compile",
            "--platform", "macosx_14_0_arm64", "--only-binary=:all:",
            "--index-url", "https://pypi.org/simple", "--timeout", "20", "--retries", "2",
            "--find-links", str(wheels), "mlx-audio[stt]==0.5.4", "mlx-whisper==0.4.3",
            str(next(wheels.glob("gigaam-*.whl"))), "antlr4-python3-runtime==4.9.3",
            "torch==2.10.0", "torchaudio==2.10.0")
        # Validate after moving: no venv, absolute interpreter link or builder path.
        moved = work / "relocated" / "runtime"
        moved.parent.mkdir()
        runtime.rename(moved)
        runtime = moved
        python = runtime / "bin/python3"
        run("-c", "import ssl,mlx.core,mlx_whisper,mlx_audio.stt,gigaam; print('Relocated runtime imports OK')")
        site = runtime / "lib/python3.11/site-packages"
        packages = sorted(f"{item.metadata['Name']}=={item.version}"
                          for item in importlib.metadata.distributions(path=[str(site)]))
        (args.output / "packages.txt").write_text("\n".join(packages) + "\n")
        # Local wheel URLs and generated scripts are publisher-only metadata.
        for item in site.glob("*.dist-info/direct_url.json"):
            item.unlink()
        shutil.rmtree(site / "bin", ignore_errors=True)
        for item in runtime.rglob("__pycache__"):
            shutil.rmtree(item)
        for item in runtime.rglob("*"):
            if item.is_symlink() and not item.resolve().is_relative_to(runtime.resolve()):
                raise RuntimeError(f"External runtime symlink: {item.relative_to(runtime)}")
        output = args.output / "SuperDictate-SpeechRuntime.tar.gz"
        pending = output.with_suffix(".pending")
        with tarfile.open(pending, "w:gz") as target:
            target.add(runtime, arcname="runtime", filter=public_metadata)
        pending.replace(output)
        manifest = dict(schema=1, sha256=digest(output), bytes=output.stat().st_size,
                        unpackedBytes=sum(p.stat().st_size for p in runtime.rglob("*") if p.is_file()),
                        url="https://github.com/shlgd/SuperDictate/releases/download/v0.2.48/SuperDictate-SpeechRuntime.tar.gz",
                        minimumMacOS="14.0", architecture="arm64")
        (args.output / "speech-runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(manifest), flush=True)


if __name__ == "__main__":
    main()
