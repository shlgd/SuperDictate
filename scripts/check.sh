#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh uninstall.sh scripts/build-app.sh scripts/check.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
installer_version="$(sed -n 's/^RELEASE_VERSION="\([^"]*\)"$/\1/p' install.sh)"
[[ -n "$installer_version" && "$app_version" == "$installer_version" ]] || {
    printf 'Version mismatch: Info.plist=%s install.sh=%s\n' "$app_version" "$installer_version" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

! grep -q 'raw.githubusercontent.com/shlgd/SuperDictate/main/' README.md
grep -q 'raw.githubusercontent.com/shlgd/SuperDictate/v'"$app_version"'/' README.md
grep -q '^REF="${SUPERDICTATE_REF:-v\$RELEASE_VERSION}"$' install.sh
grep -q '^EXPECTED_SOURCE_COMMIT="${SUPERDICTATE_SOURCE_COMMIT:-\$SOURCE_COMMIT}"$' install.sh
grep -q 'verify_source_ref' install.sh
grep -q 'validate_output_app_path "$OUTPUT_APP"' scripts/build-app.sh

git diff --check
printf 'SuperDictate checks passed (v%s).\n' "$app_version"
