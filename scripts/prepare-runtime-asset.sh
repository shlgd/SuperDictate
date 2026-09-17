#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/swift/Resources/speech-runtime.json"
TARGET="$ROOT/dist/speech-runtime/SuperDictate-SpeechRuntime.tar.gz"
SHA="$(plutil -extract sha256 raw -o - "$MANIFEST")"
if [[ -f "$TARGET" && "$(shasum -a 256 "$TARGET" | awk '{print $1}')" == "$SHA" ]]; then
    exit 0
fi
mkdir -p "$(dirname "$TARGET")"
TEMP="$(mktemp "$(dirname "$TARGET")/.runtime-download.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT
curl --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 \
    --speed-limit 1024 --speed-time 60 "$(plutil -extract url raw -o - "$MANIFEST")" -o "$TEMP"
[[ "$(shasum -a 256 "$TEMP" | awk '{print $1}')" == "$SHA" ]] || { printf 'Packaged runtime checksum mismatch\n' >&2; exit 1; }
mv "$TEMP" "$TARGET"
