# SuperDictate

[Русский](README.md) | **English**

## Install in one minute

**Requires a Mac with Apple Silicon (`M1` or later) and macOS 14+.**

1. Open the **Terminal** app.
2. Paste this command and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/install.sh | /usr/bin/arch -arm64 /bin/bash
```

3. In the SuperDictate window that opens, click `Grant` for **Microphone**,
   **Accessibility**, and **Input Monitoring**.
4. Wait for the `Running` status, press **right Command**, and start speaking.
   Press **right Command** again to insert the text.

On the first launch, a local recognition model is downloaded once. It takes
about 460 MB of disk space; having at least 1 GB free is recommended for
installation. After it is downloaded, dictation does not require an internet
connection.

SuperDictate provides fast, local dictation for macOS. Audio and transcripts
are not sent to a cloud API.

## Update

**If SuperDictate already has an `Update` button:** open the app from the
Applications folder and click the button. The app will download and verify the
new version, replace the old one, and relaunch itself.

**If SuperDictate was installed before the update button was added:** do not
delete anything. Open Terminal and run the same command again:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/main/install.sh | /usr/bin/arch -arm64 /bin/bash
```

The command replaces only `/Applications/SuperDictate.app`. Your history,
settings, and previously downloaded model remain in place. After this, future
updates can be installed directly from the app.

You can also always see the latest published version on the
[GitHub Releases](https://github.com/shlgd/SuperDictate/releases/latest) page.

## Hotkeys

- **Right Command** — start dictation; pressing it again stops recording.
- In settings, you can choose what the second press does: insert the text only,
  or insert the text and then press Enter.
- **Right Option + right Command** — an alternative way to finish an active
  recording. It performs the opposite action: if the primary hotkey presses
  Enter, this one finishes without Enter, and vice versa. The alternative
  hotkey can be disabled.
- **Right Shift + right Command** — open or close quick history.
- All three shortcuts can be changed independently. Single keys, function keys,
  regular shortcuts, and modifier-only shortcuts such as `Option + Command`
  are supported.
- Left and right modifier keys are distinguished: a shortcut using right
  Command is not triggered by left Command.
- While the window for recording a new shortcut is open, global dictation is
  temporarily paused. Pressed keys only record the new hotkey and do not
  trigger anything.
- Open `SuperDictate` from Applications to check the service, permissions, and
  updates. Open settings with the gear button.

## Control panel

The main panel is compact: it shows the background service status, missing
permissions, and an available update. Service controls are located to the
right of its status; hovering over them displays an explanation for each
button in macOS.

The gear opens a separate window with the three shortcuts, completion
behavior, capsule size, and the indicator's colors and background. The
`RU / EN` switch instantly changes the language of both panels. Changes first
remain as a draft; the `Save & Restart` button applies them together and
restarts only the background service. Your history and model are not deleted.

You can close the panel completely. The separate background service will keep
running and start automatically after the next macOS login.

## Why the permissions are needed

macOS does not allow the app to grant them to itself:

- **Microphone** — record your voice during active dictation.
- **Accessibility** — find the active field and insert the finished text.
- **Input Monitoring** — detect the global hotkey.

If the status does not become `Ready` after granting permissions, open
SuperDictate and click `Restart` for the background service. If the app does
not appear in the system list, click `Try Again` for the relevant permission.

## What the installer does

The installer:

1. Downloads `SuperDictate.zip` from
   [GitHub Releases](https://github.com/shlgd/SuperDictate/releases).
2. Verifies the pinned SHA-256, version, bundle ID, arm64 architecture,
   signature, and microphone entitlements.
3. Safely replaces `/Applications/SuperDictate.app` and opens the panel.

Xcode and Command Line Tools are not required for a normal installation.
History, settings, and the previously downloaded model are preserved during
updates.

## More about updating

### If v0.2.26 or later is installed

1. Open `SuperDictate` from the Applications folder.
2. The panel will show the new version in its bottom row.
3. Click `Update`.

The archive will be downloaded and checked for its SHA-256, bundle ID, version,
and signature. The app will then replace itself and reopen. Your history,
settings, and model are preserved. The previous version is restored
automatically if an error occurs.

### If v0.2.25 or earlier is installed

These versions do not have the button yet. Run the installation command below
one more time. It will update the app without deleting your history, settings,
or model. All subsequent updates can be installed using the button in the
panel.

The same command remains a fallback for any version:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/install.sh | /usr/bin/arch -arm64 /bin/bash
```

The app does not install updates by itself in the background: starting an
update must always be confirmed with the button.

## Build from source

### The easiest way

This command downloads the open source, builds it locally, and installs the
result in `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/install.sh | SUPERDICTATE_BUILD_FROM_SOURCE=1 /usr/bin/arch -arm64 /bin/bash
```

The free Apple Command Line Tools are required. If they are not installed, the
installer opens the standard installation dialog; after it finishes, run the
command again. The first clean build usually takes several minutes.

By default, a source build downloads the exact source commit for the release
and verifies it through GitHub. For development, you can pass your own
`SUPERDICTATE_REF` and `SUPERDICTATE_SOURCE_COMMIT`; if the commit does not
match, the installer will not run the downloaded `scripts/build-app.sh`.

### Manual development build

```bash
xcode-select --install
git clone https://github.com/shlgd/SuperDictate.git
cd SuperDictate
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
open ./dist/SuperDictate.app
```

By default, a local build is signed ad hoc. To use your own certificate, pass
its name:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh ./dist/SuperDictate.app
```

Do not move or delete `dist/SuperDictate.app` while the background service is
running from this build. For normal use, prefer the command with
`SUPERDICTATE_BUILD_FROM_SOURCE=1`, which installs the app in `/Applications`.

## Checks before a pull request

```bash
bash -n install.sh uninstall.sh scripts/build-app.sh
plutil -lint swift/Info.plist entitlements.plist
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
```

GitHub Actions repeats the self-tests, builds the bundle, runs the installer
on a clean macOS runner, and verifies uninstallation.

## Limitations

- Only Apple Silicon and macOS 14 or later are supported. Intel Macs, Windows,
  and Linux are not currently supported.
- The public build is signed ad hoc and is not notarized by Apple. Installation
  using the command above is verified, but a ZIP downloaded manually through
  a browser may trigger a Gatekeeper warning.
- Because there is no stable Developer ID signature, macOS sometimes requests
  permissions again after an update. Notarization requires a paid Apple
  Developer account.
- The first launch requires an internet connection to download the model. The
  panel checks for updates when opened; if enabled, the background check
  accesses the public GitHub API every six hours.
- A recording ends automatically after 20 minutes. If the app crashes, the
  unfinished recording is saved so its history can be recovered.
- Protected password fields and apps that hide Accessibility data may not
  provide caret coordinates. This affects the animation's position but does
  not always prevent text insertion.
- Approximate resource usage for the current build: about 460 MB of disk space
  for the model, roughly 100–150 MB of memory while idle, and up to 500 MB while
  the model is loading or running. Values depend on macOS and recording length.

## Data and privacy

- History and settings: `~/Library/Application Support/SuperDictate`.
- FluidAudio model: `~/Library/Application Support/FluidAudio/Models`.
- LaunchAgent: `~/Library/LaunchAgents/com.local.superdictate.agent.plist`.
- Logs: `~/Library/Logs/SuperDictate*`.
- There are no analytics, accounts, or telemetry.

For details, see [PRIVACY.md](PRIVACY.md).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.37/uninstall.sh | bash
```

The app and background service are removed. Your history, settings, and model
are preserved to prevent accidental data loss and avoid downloading the model
again.

## Origin and license

SuperDictate is based on Richard Courtman's open source
[Parakey](https://github.com/rcourtman/parakey) project. The original and
modified code is distributed under the MIT License. See [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md).
