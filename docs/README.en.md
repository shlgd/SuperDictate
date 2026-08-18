# SuperDictate

**English** | [Русский](README.md)

Fast, private, local push-to-talk dictation for macOS on Apple Silicon (M1 and newer, including MacBook Neo / A18 Pro).

- **100% On-Device & Private:** Speech recognition runs entirely locally on your Mac via Apple Neural Engine (CoreML). No cloud audio streaming, no telemetry, and no account required.
- **Instant Launch (< 0.2 ms):** Fast Model Integrity Fingerprint Cache completely eliminates slow SHA-256 startup verification delays.
- **Optimized for 8 GB RAM:** Eager memory deallocation and lifecycle management designed for unified memory efficiency.
- **ProMotion 120Hz Fluid UI:** Floating glassmorphic recording HUD with real-time hardware-synchronized audio waveform visualizer.
- **Multilingual Recognition:** Powered by the Parakeet TDT v3 (0.6B) model with automatic language detection (English, Russian, Spanish, French, German, and more).

---

## 1-Minute Quick Start

**Requires a Mac with Apple Silicon (`M1` or newer, including A18 Pro) and macOS 14+.**

1. Open **Terminal.app**.
2. Paste and run this command:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.40/install.sh | /usr/bin/arch -arm64 /bin/bash
```

3. When SuperDictate opens, grant permissions for **Microphone**, **Accessibility**, and **Input Monitoring**.
4. Once the status shows `Running`, press **Right Command** and start speaking.
   Press **Right Command** again to finish and paste the transcript.

On first launch, the local speech model (~475 MB) downloads once. After that, internet access is never needed for dictation.

---

## Updating

- **Direct in-app update:** Open SuperDictate from the Applications folder and click `Update`. The app verifies the cryptographic signature, replaces itself atomically, and relaunches smoothly.
- **Terminal update:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/main/install.sh | /usr/bin/arch -arm64 /bin/bash
  ```
  Your history, custom corrections, settings, and downloaded models are completely preserved.

---

## Hotkeys & Shortcuts

- **Right Command** — Start dictation; pressing it again stops recording and inserts the text.
- **Completion Behavior** — Choose between inserting text only, or inserting text followed by an automatic `Enter`.
- **Right Option + Right Command** — Alternate completion shortcut (inverts the default behavior, e.g. without pressing Enter).
- **Right Shift + Right Command** — Toggle recent transcript history overlay.
- **Custom Hotkeys** — All three shortcuts can be customized in Settings (supports single keys, function keys, chords, and modifier-only combinations).
- Global dictation is paused while the hotkey recorder panel is open to avoid unwanted triggers.

---

## Control Panel & Settings

The compact Control Panel provides:
- Live background service status (`Running` / `Stopped`).
- Permission status indicators and quick-fix buttons.
- In-app update notifications.
- Settings gear opens the configuration panel:
  - Hotkey recorder.
  - Microphone selector (with automatic CoreAudio aggregate filtering).
  - Recording HUD size, colors, and background theme (System / Dark / Light).
  - Instant **RU / EN** interface language switch.
  - Custom text replacement / autocorrection rules.
  - Optional trailing period removal (`Text processing`).

---

## Optional AI Text Cleanup (BYOK)

By default, dictation is 100% local. If desired, you can enable optional AI text cleanup to polish grammar, formatting, and punctuation via any OpenAI-compatible API endpoint (Groq, OpenAI, DeepSeek, OpenRouter):

1. Obtain an API key from your preferred provider (e.g. Groq free tier at [console.groq.com](https://console.groq.com/keys)).
2. Go to **Settings** → **AI Text Cleanup**, paste your key, and click **Save Key** (saved securely in macOS Keychain).
3. Set your base URL and model (default: `https://api.groq.com/openai/v1` and `openai/gpt-oss-20b`), test the connection, and save.
4. If the server is unreachable or errors out, SuperDictate falls back to the original local transcript immediately without loss.

---

## Permissions Overview

macOS requires explicit authorization for system integrations:
- **Microphone:** Capturing speech audio during active recording.
- **Accessibility:** Locating the active text field and pasting transcribed text.
- **Input Monitoring:** Listening for global push-to-talk hotkey triggers.

---

## Building from Source

### Quick Source Build
```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.40/install.sh | SUPERDICTATE_BUILD_FROM_SOURCE=1 /usr/bin/arch -arm64 /bin/bash
```

### Manual Local Development
```bash
xcode-select --install
git clone https://github.com/shlgd/SuperDictate.git
cd SuperDictate
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
open ./dist/SuperDictate.app
```

---

## Self-Tests & Quality Verification

Run the autonomous 24-suite diagnostic test runner before submitting pull requests:
```bash
./scripts/check.sh
swift run -c debug --package-path swift Parakey --self-test all
```

---

## Data & Privacy

- Settings & History: `~/Library/Application Support/SuperDictate`
- Local Speech Models: `~/Library/Application Support/FluidAudio/Models`
- Background LaunchAgent: `~/Library/LaunchAgents/com.local.superdictate.agent.plist`
- Logs: `~/Library/Logs/SuperDictate*`
- AI API Keys: Stored exclusively in macOS Keychain.
- Zero analytics, zero metrics telemetry, zero external tracking.

See [PRIVACY.md](PRIVACY.md) for full details.

---

## Developer Documentation

- [Code & Architecture Reference (CODE_DOCUMENTATION.md)](CODE_DOCUMENTATION.md) — Modular subsystem design, memory safety, and CoreML integration.
- [Design Philosophy (DESIGN_PHILOSOPHY.md)](DESIGN_PHILOSOPHY.md) — Low-latency design, 8 GB RAM efficiency, and local-first architecture.
- [Development Invariants (AGENTS.md)](AGENTS.md) — Bundle structure, local installation, and codesigning rules.

---

## License & Attribution

SuperDictate is based on the open-source project [Parakey](https://github.com/rcourtman/parakey) by Richard Courtman. Distributed under the MIT License. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
