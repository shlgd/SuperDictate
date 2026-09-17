#!/bin/sh
# Smoke-test tripwire: installation must not invoke development tools.
printf '%s %s\n' "${0##*/}" "$*" >> "$SUPERDICTATE_BUILD_TOOL_PROBE"
printf '%s\n' 'Development tools are unavailable in this installation test.' >&2
exit 97
