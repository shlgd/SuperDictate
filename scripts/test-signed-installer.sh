#!/bin/bash
# Exercise the real installer in an isolated directory, without launching any app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${SUPERDICTATE_TEST_ARCHIVE:-$ROOT/dist/SuperDictate.zip}"
[[ -f "$ARCHIVE" ]] || { printf 'Run scripts/package-release.sh first.\n' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-installer-signature-tests.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
APP="$WORK/Applications/SuperDictate.app"
mkdir -p "$WORK/Applications"
install_archive() {
    SUPERDICTATE_APP_PATH="$APP" \
    SUPERDICTATE_RELEASE_URL="file://$1" \
    SUPERDICTATE_RELEASE_SHA256="$(shasum -a 256 "$1" | awk '{print $1}')" \
    SUPERDICTATE_SKIP_MODEL_INSTALL=1 SUPERDICTATE_NO_OPEN=1 bash "$ROOT/install.sh"
}
install_archive "$ARCHIVE" > "$WORK/first.log" 2>&1 || { cat "$WORK/first.log"; exit 1; }
plutil -replace CFBundleVersion -string signing-test "$APP/Contents/Info.plist"
bash "$ROOT/scripts/release-signing.sh" sign "$APP" "$ROOT/entitlements.plist"
install_archive "$ARCHIVE" > "$WORK/update.log" 2>&1 || { cat "$WORK/update.log"; exit 1; }
BEFORE="$(codesign -dv "$APP" 2>&1)"
ditto -x -k "$ARCHIVE" "$WORK/adhoc"
codesign --force --sign - --entitlements "$ROOT/entitlements.plist" "$WORK/adhoc/SuperDictate.app"
ditto -c -k --sequesterRsrc --keepParent "$WORK/adhoc/SuperDictate.app" "$WORK/adhoc.zip"
if install_archive "$WORK/adhoc.zip" > "$WORK/rejected.log" 2>&1; then
    printf 'FAIL: installer accepted ad-hoc downgrade\n' >&2; exit 1
fi
grep -q 'Подпись обновления отличается' "$WORK/rejected.log"
[[ "$BEFORE" == "$(codesign -dv "$APP" 2>&1)" ]]
codesign --verify --deep --strict "$APP"
printf 'PASS: real installer accepts the stable identity and leaves installed files intact on an ad-hoc downgrade.\n'
