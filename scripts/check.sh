#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh uninstall.sh scripts/build-app.sh scripts/check.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
installer_version="$(sed -n 's/^RELEASE_VERSION="\([^"]*\)"$/\1/p' install.sh)"
installer_sha256="$(sed -n 's/^RELEASE_SHA256="\([^"]*\)"$/\1/p' install.sh)"
manifest_version="$(plutil -extract version raw -o - update.json)"
manifest_sha256="$(plutil -extract sha256 raw -o - update.json)"
[[ -n "$installer_version" && "$app_version" == "$installer_version" ]] || {
    printf 'Version mismatch: Info.plist=%s install.sh=%s\n' "$app_version" "$installer_version" >&2
    exit 1
}
[[ "$manifest_version" == "$app_version" ]] || {
    printf 'Version mismatch: Info.plist=%s update.json=%s\n' "$app_version" "$manifest_version" >&2
    exit 1
}
[[ "$manifest_sha256" == "$installer_sha256" && "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Checksum mismatch: install.sh=%s update.json=%s\n' "$installer_sha256" "$manifest_sha256" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

git diff --check
printf 'SuperDictate checks passed (v%s).\n' "$app_version"
