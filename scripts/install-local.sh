#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="/Applications/SuperDictate.app"
AGENT_LABEL="com.local.superdictate.agent"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-local-install.XXXXXX")"
STAGED_APP="$WORK_DIR/SuperDictate.app"
INCOMING="/Applications/.SuperDictate.incoming.$$"
BACKUP="/Applications/.SuperDictate.previous.$$"

cleanup() {
    rm -rf "$WORK_DIR" "$INCOMING"
}
trap cleanup EXIT

identity="${SUPERDICTATE_SIGN_IDENTITY:-}"
release_identity=0
if [[ -z "$identity" && -d "$APP_PATH" ]] && \
    codesign --verify --strict "-R=certificate leaf = H\"$(cat "$ROOT_DIR/release-signing.sha1")\"" "$APP_PATH" 2>/dev/null; then
    release_identity=1
fi
if [[ -z "$identity" && -d "$APP_PATH" ]]; then
    identity="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 \
        | sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' \
        | head -n 1)"
fi
if [[ -z "$identity" && "$release_identity" == "0" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
        | head -n 1)"
fi
if [[ -z "$identity" && "$release_identity" == "0" ]]; then
    printf 'SuperDictate: no Apple Development signing identity was found.\n' >&2
    printf 'Set SUPERDICTATE_SIGN_IDENTITY explicitly; ad-hoc local installs are disabled because they reset macOS permissions.\n' >&2
    exit 1
fi

if [[ "$release_identity" == "1" ]]; then
    SUPERDICTATE_RELEASE_BUILD=1 "$ROOT_DIR/scripts/build-app.sh" "$STAGED_APP"
else
    SIGN_IDENTITY="$identity" "$ROOT_DIR/scripts/build-app.sh" "$STAGED_APP"
fi

codesign --verify --deep --strict "$STAGED_APP"
identifier="$(codesign -d --verbose=4 "$STAGED_APP" 2>&1 \
    | sed -n 's/^Identifier=//p')"
[[ "$identifier" == "com.local.superdictate" ]] || {
    printf 'SuperDictate: unexpected bundle identifier: %s\n' "$identifier" >&2
    exit 1
}
if [[ -d "$APP_PATH" ]]; then
    installed_requirement="$(codesign -d -r- "$APP_PATH" 2>&1 | tail -n 1)"
    staged_requirement="$(codesign -d -r- "$STAGED_APP" 2>&1 | tail -n 1)"
    [[ "$installed_requirement" == "$staged_requirement" ]] || {
        printf 'SuperDictate: refusing to change the installed signing identity because that would reset macOS permissions.\n' >&2
        exit 1
    }
fi

uid="$(id -u)"
launchctl bootout "gui/$uid/$AGENT_LABEL" >/dev/null 2>&1 || true
pkill -f '/Applications/SuperDictate.app/Contents/MacOS/SuperDictate' >/dev/null 2>&1 || true

ditto "$STAGED_APP" "$INCOMING"
codesign --verify --deep --strict "$INCOMING"

if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$BACKUP"
fi
if ! mv "$INCOMING" "$APP_PATH"; then
    if [[ -e "$BACKUP" ]]; then
        mv "$BACKUP" "$APP_PATH"
    fi
    exit 1
fi
rm -rf "$BACKUP"

launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$uid/$AGENT_LABEL"

printf 'SuperDictate: installed one signed app at %s and restarted the background agent.\n' "$APP_PATH"
