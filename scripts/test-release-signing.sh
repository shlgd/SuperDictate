#!/bin/bash
# Signature tests only: never launch/register a fixture app or touch TCC grants.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-signature-tests.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
swift build --package-path "$ROOT/swift"
BIN_DIR="$(swift build --package-path "$ROOT/swift" --show-bin-path)"
A="$WORK/a/SuperDictate.app"
B="$WORK/b/SuperDictate.app"
C="$WORK/c/SuperDictate.app"
mkdir -p "$A/Contents/MacOS"
cp /usr/bin/true "$A/Contents/MacOS/SuperDictate"
plutil -create xml1 "$A/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.local.superdictate "$A/Contents/Info.plist"
plutil -insert CFBundleExecutable -string SuperDictate "$A/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$A/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 1.0.0 "$A/Contents/Info.plist"
bash "$ROOT/scripts/release-signing.sh" sign "$A"
ditto "$A" "$B"
plutil -replace CFBundleShortVersionString -string 1.0.1 "$B/Contents/Info.plist"
bash "$ROOT/scripts/release-signing.sh" sign "$B"
check() {
    SUPERDICTATE_TEST_INSTALLED="$1" SUPERDICTATE_TEST_CANDIDATE="$2" "$BIN_DIR/Parakey" --self-test update-signing
}
reject() {
    if check "$1" "$2"; then printf 'FAIL: incompatible signature was accepted\n' >&2; exit 1; fi
}
check "$A" "$B"
requirement="$(codesign -d -r- "$A" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$requirement" ]]
codesign --verify --deep --strict "-R=$requirement" "$B"
ditto "$B" "$C"
codesign --force --sign - "$C"
reject "$A" "$C"
check "$C" "$B" # one-time migration from legacy ad-hoc
SUPERDICTATE_SIGNING_STORE="$WORK/other-identity" bash "$ROOT/scripts/release-signing.sh" init >/dev/null 2>&1
SUPERDICTATE_SIGNING_STORE="$WORK/other-identity" bash "$ROOT/scripts/release-signing.sh" sign "$C"
reject "$A" "$C"
plutil -replace CFBundleShortVersionString -string 1.0.2 "$B/Contents/Info.plist"
reject "$A" "$B"
printf 'PASS: same identity accepted; ad-hoc downgrade, different certificate, tampering rejected; legacy migration accepted.\n'
