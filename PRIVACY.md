# Privacy

SuperDictate is designed for local dictation.

## Data that stays on the Mac

- Microphone audio is processed locally and is not sent to a transcription API.
- Successful transcripts, timing statistics, corrections, and preferences are
  stored under `~/Library/Application Support/SuperDictate`.
- Diagnostic logs are stored under `~/Library/Logs` and avoid transcript text.
- Pending audio is kept only as a crash-recovery safeguard and is removed after
  it has been handled. Recovery files that were never successfully handled are
  deleted automatically once they are older than 24 hours, so a failed recovery
  cannot leave audio on disk indefinitely.
- The speech model is cached by FluidAudio under
  `~/Library/Application Support/FluidAudio/Models`.

## Retention

Transcript history is kept until you delete it, unless you set an expiry.

- **Settings → Text → Keep History For** — `Keep forever` (default),
  `1 day`, `7 days` or `30 days`. Transcripts older than the chosen window are
  deleted from disk at launch, when history is written, when the history overlay
  opens, and on an hourly sweep.
- **Settings → Text → Recent Transcripts** is a separate, count-based cap on how
  many entries the overlay shows. The two limits combine: an entry must be
  within both to survive. Setting it to `Off` keeps no history at all.
- **Settings → Text → Clear Private Data Now…** deletes every saved transcript
  and any leftover crash-recovery audio immediately, after a confirmation. It
  does not touch your settings, custom corrections or the speech model.

The default is `Keep forever` so that updating SuperDictate never deletes
history you did not ask it to delete. Entries saved before retention existed are
given a creation date the first time the new version starts, so they begin their
retention window then rather than expiring at once.

## Network access

SuperDictate uses the network only to download the speech model through
FluidAudio and to check the public GitHub releases endpoint for updates. The
installer downloads the application from the same public repository. It has no
account system, advertising, analytics, or telemetry.

## macOS permissions

- **Microphone** records speech while dictation is active.
- **Accessibility** inserts the resulting text into the focused field.
- **Input Monitoring** observes the configured global hotkey.
