#!/bin/bash
# Exercise the real update helper on release archives without launching fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLD="$ROOT/dist/SuperDictate-v0.2.47-upgrade-fixture.zip"
NEW="$ROOT/dist/SuperDictate.zip"
[[ "$(shasum -a 256 "$OLD" | awk '{print $1}')" == "028e3489a39f15392a4d7de5c21a6ab555f245c6a46776c926c00cf07ab10ca3" ]]
[[ "$(stat -f%z "$NEW")" -lt 67108864 ]]
WORK="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-release-upgrade.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
ditto -x -k "$OLD" "$WORK/old"
ditto -x -k "$NEW" "$WORK/new"
SUPERDICTATE_TEST_INSTALLED="$WORK/old/SuperDictate.app" \
SUPERDICTATE_TEST_CANDIDATE="$WORK/new/SuperDictate.app" \
    "$ROOT/swift/.build/debug/Parakey" --self-test release-upgrade
printf 'PASS: real 0.2.47 -> 0.2.48 replacement, stable signing, old archive limit, no fixture launched.\n'
