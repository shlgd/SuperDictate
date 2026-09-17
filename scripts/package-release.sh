#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-release.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
SUPERDICTATE_RELEASE_BUILD=1 SUPERDICTATE_RUNTIME_MODE=download bash "$ROOT/scripts/build-app.sh" "$WORK/SuperDictate.app"
codesign --verify --deep --strict "-R=certificate leaf = H\"$(cat "$ROOT/release-signing.sha1")\"" "$WORK/SuperDictate.app"
mkdir -p "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent "$WORK/SuperDictate.app" "$WORK/SuperDictate.zip"
mv "$WORK/SuperDictate.zip" "$ROOT/dist/SuperDictate.zip"
[[ "$(stat -f%z "$ROOT/dist/SuperDictate.zip")" -lt 67108864 ]] || { printf 'Bridge update exceeds old updater limit\n' >&2; exit 1; }
SUPERDICTATE_RELEASE_BUILD=1 SUPERDICTATE_RUNTIME_MODE=embedded bash "$ROOT/scripts/build-app.sh" "$WORK/SuperDictate.app"
ditto -c -k --sequesterRsrc --keepParent "$WORK/SuperDictate.app" "$WORK/SuperDictate-full.zip"
mv "$WORK/SuperDictate-full.zip" "$ROOT/dist/SuperDictate-full.zip"
shasum -a 256 "$ROOT/dist/SuperDictate.zip"
printf 'Archive prepared locally. Nothing published; update version and manifests only for a tested release.\n'
