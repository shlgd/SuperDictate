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

SuperDictate uses the network to download the speech model through
FluidAudio and to check the public GitHub releases endpoint for updates. The
installer downloads the application from the same public repository. It has no
account system, advertising, analytics, or telemetry.

### Optional AI cleanup (off by default)

If you explicitly enable **AI cleanup** and provide your own API key, the
finished transcript text — never microphone audio — is sent over HTTPS to the
OpenAI-compatible endpoint you configure (default: `https://api.groq.com/openai/v1`)
for grammar and punctuation correction. The API key is stored only in the
macOS Keychain (service `com.local.superdictate.ai`), never in preferences
files, logs, or this repository. Endpoint and model are user-editable, so the
data destination is entirely your choice; note that some providers (including
OpenCode Zen's free models) may retain submitted text. If the request fails
for any reason, the locally produced transcript is used instead and nothing
is retried or queued. With the feature off — the default — no transcript text
ever leaves the Mac.

## macOS permissions

- **Microphone** records speech while dictation is active.
- **Accessibility** inserts the resulting text into the focused field.
- **Input Monitoring** observes the configured global hotkey.
