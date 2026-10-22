#!/bin/bash
# Exercise the real update helper on release archives without launching fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLD="$ROOT/dist/SuperDictate-v0.2.48-upgrade-fixture.zip"
NEW="$ROOT/dist/SuperDictate.zip"
[[ "$(shasum -a 256 "$OLD" | awk '{print $1}')" == "bc360b75c9c20870d9799b01f039d75c54af7cb7c8a828a00a06513a41f4baed" ]]
[[ "$(stat -f%z "$NEW")" -lt 67108864 ]]
WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-release-upgrade.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
ditto -x -k "$OLD" "$WORK/old"
ditto -x -k "$NEW" "$WORK/new"
SUPERDICTATE_TEST_INSTALLED="$WORK/old/SuperDictate.app" \
SUPERDICTATE_TEST_CANDIDATE="$WORK/new/SuperDictate.app" \
    "$ROOT/swift/.build/debug/Parakey" --self-test release-upgrade
printf 'PASS: real 0.2.48 -> 0.2.49 replacement, stable signing, old archive limit, no fixture launched.\n'
