# SuperDictate Code Documentation

SuperDictate is a high-performance, local-first push-to-talk dictation application built in Swift for macOS on Apple Silicon (`M1` through `M4` and `A18 Pro` / MacBook Neo).

---

## 1. High-Level Architecture

The codebase is organized into modular layers located in `swift/Sources/Parakey/`:

```
swift/Sources/Parakey/
├── Core/                     # Core services, logging, settings, hotkeys, permissions
│   ├── Constants.swift
│   ├── Logger.swift
│   ├── Permissions.swift
│   ├── AgentService.swift
│   ├── Settings.swift
│   └── HotkeyListener.swift
├── Audio/                    # Audio capture, sample rate conversion, device management
│   ├── AudioCapture.swift
│   ├── AudioConverter.swift
│   ├── AudioDeviceManager.swift
│   └── SystemAudioMute.swift
├── Speech/                   # Neural speech recognition & CoreML pipeline
│   ├── SpeechModelProfile.swift
│   ├── SpeechModelProgress.swift
│   ├── ModelIntegrity.swift
│   └── TranscriptionWorker.swift
├── Text/                     # Text cleanup, custom corrections, insertion strategies
│   ├── TextProcessing.swift
│   ├── TranscriptCorrector.swift
│   ├── AICleanupService.swift
│   └── TextInsertionStrategy.swift
├── UI/                       # Status bar, control panel, HUD, history, statistics
│   ├── RecordingHUDView.swift
│   ├── MenuBarController.swift
│   ├── SettingsWindow.swift
│   ├── HistoryWindow.swift
│   ├── StatisticsView.swift
│   └── UpdateProgressWindow.swift
├── Localization/             # Multi-language string tables & locale manager
│   ├── Localization.swift
│   └── LocalizationManager.swift
├── Diagnostics/              # Comprehensive test suites and diagnostic runner
│   ├── DiagnosticsRunner.swift
│   └── SelfTests.swift
└── main.swift                # Unified CLI & process router
```

---

## 2. Core Subsystems

### 2.1 Core Subsystem (`Core/`)
- **`Constants.swift`**: Defines timing thresholds (`MIN_CLIP_SECONDS = 0.2`, `SAMPLE_RATE = 16_000.0`), bundle identifiers, file paths, and memory monitoring helpers (`AppMemoryUsage`).
- **`Logger.swift`**: POSIX thread-safe logging with file descriptors (`PRIVATE_LOG_FILE_MODE = 0o600`) directly to `~/Library/Logs/SuperDictate.log`.
- **`Permissions.swift`**: Non-blocking asynchronous checks for Microphone (`AVCaptureDevice`), Accessibility (`AXIsProcessTrusted`), and Input Monitoring (`CGPreflightListenEventAccess`).
- **`AgentService.swift`**: Manages `launchd` registration (`com.local.superdictate.agent`) via `SMAppService` and `launchctl`.
- **`Settings.swift`**: Type-safe UserDefaults wrapper, hotkey choice structures, dictation completion behaviors, history retention, and latency metrics.
- **`HotkeyListener.swift`**: Low-level global event tap (`CGEventTapCreate`) intercepting keydown/keyup events without polling.

### 2.2 Audio Subsystem (`Audio/`)
- **`AudioCapture.swift`**: Manages `AVAudioEngine`, installs audio tap, handles audio stream routing, and flushes raw PCM Float32 segments into atomic crash-recovery journals.
- **`AudioConverter.swift`**: Downmixes multi-channel inputs and converts sample rates to 16,000 Hz mono using `AVAudioConverter`.
- **`AudioDeviceManager.swift`**: CoreAudio hardware device discovery and filtering out temporary `CADefaultDeviceAggregate-` pseudo-devices.
- **`SystemAudioMute.swift`**: Optional ducking/muting of system playback while recording to prevent audio feedback.

### 2.3 Speech Subsystem (`Speech/`)
- **`ModelIntegrity.swift`**: Implements **Fast Model Integrity Fingerprint Cache**. Reads file metadata (`st_mtimespec`, `st_size`, `st_ino`) and validates against `model_integrity_cache.json` in **< 0.2 ms**. Automatically computes full SHA-256 digests if files change.
- **`SpeechModelProfile.swift`**: Metadata for Parakeet TDT v3 (0.6B multilingual CoreML model).
- **`SpeechModelProgress.swift`**: Byte-weighted transfer and compilation progress tracker.
- **`TranscriptionWorker.swift`**: Background actor handling `FluidAudio` model lifecycle, executing inference on Apple Neural Engine (ANE), and ensuring eager memory deallocation for 8 GB Unified Memory devices.

### 2.4 Text Subsystem (`Text/`)
- **`TextProcessing.swift`**: Strips model artifacts, fixes spacing, punctuation, capitalization, and removes trailing periods when configured.
- **`TranscriptCorrector.swift`**: User-defined regex and word replacement rules with fast single-pass substitution.
- **`AICleanupService.swift`**: Optional OpenAI-compatible REST client (Groq, OpenAI, DeepSeek) for grammar cleanup.
- **`TextInsertionStrategy.swift`**: Dual insertion pipeline:
  1. *Accessibility API (`AXUIElement`)*: Direct text attribute setting where supported.
  2. *Clipboard Paste Transaction*: Fast `Cmd+V` synthesized event with instant clipboard restoration.

### 2.5 UI Subsystem (`UI/`)
- **`RecordingHUDView.swift`**: Floating glassmorphic HUD with `CADisplayLink` (supporting 60Hz and 120Hz ProMotion displays) displaying real-time audio waveforms.
- **`MenuBarController.swift`**: Menu bar status icon (`NSStatusItem`), reactive state machine (`idle`, `recording`, `transcribing`, `busy`, `loading`, `error`), and application lifecycle coordinator.
- **`SettingsWindow.swift`**: Control panel with tabbed settings, hotkey recorder, microphone selector, and language switcher.
- **`HistoryWindow.swift`**: Searchable transcript archive with audio durations and timing tooltips.
- **`StatisticsView.swift`**: Weekly/daily dictation volume graphs and real-time speed ratios.

### 2.6 Diagnostics Subsystem (`Diagnostics/`)
- **`SelfTests.swift`**: 24 autonomous test suites verifying hotkeys, audio capture, permissions, model integrity, text transformations, paste transactions, and recovery.
- **`DiagnosticsRunner.swift`**: Generates diagnostic reports (`--diagnostics`).

---

## 3. Development and Verification

### Building and Running Self-Tests
```bash
swift run -c debug --package-path swift Parakey --self-test all
```

### Static Repository Verification
```bash
./scripts/check.sh
```

### Building the Release App Bundle
```bash
./scripts/build-app.sh ./dist/SuperDictate.app
```
