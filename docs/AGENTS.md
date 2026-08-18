# SuperDictate Development Invariants

## One Installed Application

- The only runnable installed bundle is `/Applications/SuperDictate.app`.
- Always use bundle identifier `com.local.superdictate`.
- Local installation must atomically replace that bundle and restart only
  `com.local.superdictate.agent`.
- Never launch a copied, test, smoke, or temporary `.app` bundle. Exercise
  diagnostics through the command-line self-tests instead.
- Never change the signing identity during an installation. On this Mac,
  local builds use the existing Apple Development identity so macOS keeps
  the same designated requirement and preserves granted permissions.
- Never call `tccutil reset` automatically. Permission removal is an explicit
  user action.
- Never open more than one macOS privacy pane for a permission request.

## Local Installation

Run `scripts/install-local.sh`. It builds into a temporary directory, signs
with the stable local identity when available, replaces the single installed
bundle, and restarts the background agent without opening another app window.
