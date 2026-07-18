# Privacy

SuperDictate is designed for local dictation.

## Data that stays on the Mac

- Microphone audio is processed locally and is not sent to a transcription API.
- Successful transcripts, timing statistics, corrections, and preferences are
  stored under `~/Library/Application Support/SuperDictate`.
- Diagnostic logs are stored under `~/Library/Logs` and avoid transcript text.
- Pending audio is kept only as a crash-recovery safeguard and is removed after
  it has been handled.
- The speech model is cached by FluidAudio under
  `~/Library/Application Support/FluidAudio/Models`.

## Network access

SuperDictate uses the network only to download the speech model through
FluidAudio and to check the public GitHub releases endpoint for updates. The
installer downloads the application from the same public repository. It has no
account system, advertising, analytics, or telemetry.

## macOS permissions

- **Microphone** records speech while dictation is active.
- **Accessibility** inserts the resulting text into the focused field.
- **Input Monitoring** observes the configured global hotkey.
