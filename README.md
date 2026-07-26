# SuperDictate

**Fast, fully local dictation for macOS.** Hold a key, speak, and your words are
typed into whatever app you are in. Audio and transcripts never leave your Mac —
no cloud API, no account, no telemetry.

**English** · [Русский](README.ru.md)

<!--
  TODO(maintainer): drop a short screen recording here — it is the single
  highest-conversion element a README can have. Suggested capture:
  press the hotkey, speak one sentence, watch the capsule animate and the
  text land in Slack or a browser field. 5-8 seconds, < 5 MB, e.g.

  ![SuperDictate in action](docs/demo.gif)
-->

## Why SuperDictate

- **Local speech recognition.** Parakeet TDT v3 running on the Apple Neural
  Engine via CoreML. After the one-time model download, dictation works offline.
- **18 languages**, or automatic detection — see [Languages](#languages).
- **Fast.** No network round-trip, so latency is bounded by your Mac, not your
  connection.
- **Private by construction.** No analytics, no accounts, no telemetry. History
  and settings stay in your home folder.
- **It types into any app.** Text is inserted into the focused field via
  Accessibility, not pasted into a scratch window you then have to copy from.
- **Free and MIT-licensed.**

## Requirements

- Mac with Apple Silicon (`M1` or newer)
- macOS 14 or newer
- ~460 MB of disk for the speech model (1 GB free recommended)
- Internet on first launch only, to download the model

Intel Macs, Windows and Linux are not supported.

## Install in a minute

1. Open **Terminal**.
2. Paste this command and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/install.sh | /usr/bin/arch -arm64 /bin/bash
```

3. When SuperDictate opens, click `Allow` for **Microphone**, **Accessibility**
   and **Input Monitoring**.
4. Wait for the `Ready` status, press **Right Command** and speak. Press
   **Right Command** again to insert the text.

The speech model downloads once on first launch. Xcode and Command Line Tools
are not needed for a normal install.

Prefer to read the script before running it? It is
[`install.sh`](install.sh) in this repository, and the command above is pinned
to the `v0.2.37` tag, so its contents cannot change under you. What the
installer does is described in [What the installer does](#what-the-installer-does).

## Languages

Set **Settings → Dictation language**. The default is `Auto-detect`, which is
the right choice for most people. Picking an explicit language biases the
decoder toward that script (Latin vs Cyrillic) and prevents the occasional
stray Cyrillic character that v3 can emit on Latin-script speech.

| | | | |
|---|---|---|---|
| Auto-detect | English | Spanish | French |
| German | Italian | Portuguese | Romanian |
| Polish | Czech | Slovak | Slovenian |
| Croatian | Bosnian | Russian | Ukrainian |
| Belarusian | Bulgarian | Serbian | |

The app interface itself is available in English and Russian, switched
independently of the dictation language.

## Hotkeys

- **Right Command** — start dictation. In `Press to toggle` mode (the default)
  press it again to finish; in `Press and hold` mode release it to finish.
- **Right Option + Right Command** — alternative way to finish an active
  recording. It does the opposite of your primary completion behaviour: if the
  main hotkey presses Enter, this one finishes without Enter, and vice versa.
  Can be disabled.
- **Right Shift + Right Command** — open or close the quick history panel.

All three combinations are independently configurable. Single keys, function
keys, ordinary combinations and modifier-only combinations (for example
`Option + Command`) are all supported. Left and right modifiers are distinct: a
Right Command binding will not fire from Left Command.

While the "record a new shortcut" window is open, global dictation is paused —
keys you press only record the new binding and trigger nothing.

## Settings

Open SuperDictate from Applications and click the gear icon.

**Dictation**

- `Trigger mode` — `Press to toggle` (default) or `Press and hold`.
- `Completion behaviour` — insert text, or insert text and then press Enter.
  A configurable delay before Enter (default 120 ms) helps apps that need a
  moment to register the inserted text.
- `Dictation language` — auto-detect or one of 18 languages.
- `Input device` — pick a specific microphone instead of the system default.
- `Mute other audio while recording` — on by default.

**Transcript cleanup**

- `Custom corrections` — your own find/replace list, applied to the transcript
  before it is inserted. The right fix for names, jargon, product names and
  anything the model consistently mishears. Corrections can be synced from a
  file.
- `Remove filler words` — off by default. A conservative pass that strips
  standalone `um`, `uh`, `ah`, `er`, `erm`, `hmm` (including stretched forms
  like `ummm`) and repairs the punctuation and capitalisation left behind.
  Ambiguous words such as `like` and `you know` are deliberately left alone.
  Your explicit corrections always win over filler stripping.

**Recording indicator**

A small capsule appears near your caret while recording, animating with your
voice level so you can see you are being heard.

- Show or hide the waveform
- Capsule size
- Accent colour while recording and while transcribing
- Background style

**Other**

- Interface language (`RU / EN`), applied instantly to both panels
- Feedback sounds on start and finish (on by default)
- Show in Dock (off by default — the app lives in the menu bar)
- Automatic update checks

Changes are held as a draft first; `Save and restart` applies them together and
restarts only the background service. History and the model are untouched.

## Control panel

The main panel is compact: background service status, any missing permissions,
and an available update. Service controls sit to the right of the status, with
macOS tooltips explaining each button.

You can close the panel entirely — the background service keeps running and
starts automatically after your next macOS login.

## Why the permissions

macOS does not let an app grant these to itself:

- **Microphone** — record your voice during active dictation.
- **Accessibility** — find the focused text field and insert the finished text.
- **Input Monitoring** — see the global hotkey.

If the status does not become `Ready` after granting them, open SuperDictate and
press `Restart` on the background service. If the app never appeared in the
system list, press `Try Again` next to the relevant permission.

## Updating

**If SuperDictate already has an `Update` button** (v0.2.26 and newer): open the
app from Applications and click it. The archive is downloaded and verified
against a pinned SHA-256, bundle ID, version and signature, then the app
replaces itself and relaunches. History, settings and the model are preserved,
and the previous version is restored automatically if anything fails.

**If SuperDictate was installed before the update button existed** (v0.2.25 and
older): do not delete anything. Run the install command once more — it replaces
only `/Applications/SuperDictate.app`, leaving history, settings and the
downloaded model in place. Every later update can then be installed from the
button.

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/install.sh | /usr/bin/arch -arm64 /bin/bash
```

Updates are never installed in the background — starting an update always
requires the button.

The latest published version is always visible on the
[GitHub Releases](https://github.com/shlgd/SuperDictate/releases/latest) page.

## What the installer does

1. Downloads `SuperDictate.zip` from
   [GitHub Releases](https://github.com/shlgd/SuperDictate/releases).
2. Verifies the pinned SHA-256, the version, the bundle ID, the arm64
   architecture, the code signature and the microphone entitlements.
3. Safely replaces `/Applications/SuperDictate.app` and opens the panel.

## Build from source

### Easiest way

Downloads the open source, builds it locally and installs the result into
`/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/install.sh | SUPERDICTATE_BUILD_FROM_SOURCE=1 /usr/bin/arch -arm64 /bin/bash
```

This needs the free Apple Command Line Tools. If they are missing, the
installer opens the standard install dialog; run the command again once it
finishes. The first clean build usually takes a few minutes.

By default a source build downloads the exact source commit of the release and
verifies it through GitHub. For development you can pass your own
`SUPERDICTATE_REF` and `SUPERDICTATE_SOURCE_COMMIT`; without a commit match the
installer will not run the downloaded `scripts/build-app.sh`.

### Manual development build

```bash
xcode-select --install
git clone https://github.com/shlgd/SuperDictate.git
cd SuperDictate
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
open ./dist/SuperDictate.app
```

Local builds are ad-hoc signed by default. To use your own certificate, pass its
name:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh ./dist/SuperDictate.app
```

Do not move or delete `dist/SuperDictate.app` while the background service is
running from that build. For everyday use prefer the
`SUPERDICTATE_BUILD_FROM_SOURCE=1` command, which installs into `/Applications`.

## Checks before a pull request

```bash
bash -n install.sh uninstall.sh scripts/build-app.sh
plutil -lint swift/Info.plist entitlements.plist
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
```

GitHub Actions repeats the self-tests, builds the bundle, runs the installer on
a clean macOS runner and verifies uninstallation.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Limitations

- Apple Silicon and macOS 14+ only. Intel Macs, Windows and Linux are not
  supported yet.
- The public build is ad-hoc signed and not notarized by Apple. Installing via
  the command above is verified, but a ZIP downloaded manually through a browser
  may trigger a Gatekeeper warning.
- Without a stable Developer ID signature, macOS sometimes re-asks for
  permissions after an update. Notarization requires a paid Apple Developer
  account.
- First launch needs internet to download the model. The panel checks for
  updates when opened; the background check, if enabled, calls the public GitHub
  API once every six hours.
- A single recording ends automatically after 20 minutes. If the app exits
  unexpectedly, the unfinished recording is kept so history can be recovered.
- Secure password fields, and apps that hide Accessibility data, may not expose
  caret coordinates. This affects where the animation is drawn, but does not
  always prevent text insertion.
- Resource guidance for the current build: about 460 MB on disk for the model,
  roughly 100–150 MB of memory at idle and up to 500 MB while the model loads or
  runs. Actual figures depend on macOS and recording length.

## Data and privacy

- History and settings: `~/Library/Application Support/SuperDictate`
- FluidAudio model: `~/Library/Application Support/FluidAudio/Models`
- LaunchAgent: `~/Library/LaunchAgents/com.local.superdictate.agent.plist`
- Logs: `~/Library/Logs/SuperDictate*`
- No analytics, no accounts, no telemetry.

More detail: [PRIVACY.md](PRIVACY.md). To report a vulnerability, see
[SECURITY.md](SECURITY.md).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/uninstall.sh | bash
```

This removes the app and the background service. History, settings and the model
are kept, so you do not lose data or have to download the model again by
accident.

## Credits and licence

SuperDictate is based on the open source
[Parakey](https://github.com/rcourtman/parakey) project by Richard Courtman.
Original and modified code is distributed under the MIT licence. See
[LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

Speech recognition uses
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s CoreML build of
Parakeet TDT v3.
