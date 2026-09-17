#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh uninstall.sh scripts/build-app.sh scripts/check.sh scripts/package-model.sh scripts/release-signing.sh scripts/package-release.sh scripts/test-release-signing.sh scripts/test-signed-installer.sh scripts/prepare-runtime-asset.sh scripts/test-release-upgrade.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
installer_version="$(sed -n 's/^RELEASE_VERSION="\([^"]*\)"$/\1/p' install.sh)"
installer_sha256="$(sed -n 's/^RELEASE_SHA256="\([^"]*\)"$/\1/p' install.sh)"
installer_model_sha256="$(sed -n 's/^MODEL_RELEASE_SHA256="\([^"]*\)"$/\1/p' install.sh)"
installer_model_content_sha256="$(sed -n 's/^MODEL_CONTENT_SHA256="\([^"]*\)"$/\1/p' install.sh)"
manifest_version="$(plutil -extract version raw -o - update.json)"
manifest_sha256="$(plutil -extract installerSha256 raw -o - update.json 2>/dev/null || plutil -extract sha256 raw -o - update.json)"
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
[[ "$installer_model_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Invalid model archive checksum: %s\n' "$installer_model_sha256" >&2
    exit 1
}
[[ "$installer_model_content_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Invalid model content checksum: %s\n' "$installer_model_content_sha256" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

! grep -q 'raw.githubusercontent.com/shlgd/SuperDictate/main/' README.md
grep -q 'raw.githubusercontent.com/shlgd/SuperDictate/v'"$app_version"'/' README.md
grep -q '^REF="${SUPERDICTATE_REF:-\$SOURCE_COMMIT}"$' install.sh
grep -q '^EXPECTED_SOURCE_COMMIT="${SUPERDICTATE_SOURCE_COMMIT:-\$SOURCE_COMMIT}"$' install.sh
grep -q 'verify_source_ref' install.sh
grep -q 'sysctl.proc_translated' install.sh
grep -q 'is_apple_silicon' install.sh
grep -q 'Restarting the build natively for Apple Silicon' scripts/build-app.sh
grep -q 'validate_output_app_path "$OUTPUT_APP"' scripts/build-app.sh
grep -q 'MODEL_ASSET_NAME="SuperDictate-Model-v3.zip"' install.sh
grep -q 'download_with_progress' install.sh
grep -q 'ensure_speech_model "$WORK_DIR"' install.sh
grep -q 'EXPECTED_CONTENT_SHA256=' scripts/package-model.sh

settings_save_handler="$(sed -n '/@objc private func saveSettingsClicked/,/private func captureAISettingsFields/p' swift/Sources/Parakey/main.swift)"
grep -Fq 'settingsWindow?.performClose(sender)' <<<"$settings_save_handler" || {
    printf 'Settings save handler must close the settings window after a successful save.\n' >&2
    exit 1
}

git diff --check
printf 'SuperDictate checks passed (v%s).\n' "$app_version"
