<div align="center">

# 🎙️ SuperDictate

**Fast, private, on-device push-to-talk voice dictation for macOS on Apple Silicon.**

[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS-007ACC?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![CoreML](https://img.shields.io/badge/CoreML-Apple%20Silicon-FF6F00?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/coreml)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-000000?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](../LICENSE)

[Features](#-key-features) • [Installation](#-quick-install) • [Hotkeys](#-hotkeys--controls) • [Building](#-build-from-source) • [Русская версия](README.md)

</div>

---

## 📌 Overview

**SuperDictate** is a native macOS speech-to-text dictation application designed for speed, privacy, and zero reliance on external cloud APIs. Audio transcription is processed completely on-device utilizing the **Apple Neural Engine (ANE)** through CoreML models.

---

## ✨ Key Features

- 🔒 **100% On-Device & Private:** Audio never leaves your Mac. Zero accounts, zero tracking, zero external telemetry.
- ⚡ **Instant Response (< 0.2ms startup):** Fast Fingerprint Cache eliminates model metadata parsing delays.
- 🌊 **ProMotion 120Hz Capsule UI:** Floating recording pill with hardware-accelerated audio waveform visualizer.
- 🌍 **Multilingual ASR:** Support for English, Russian, and other languages with automatic language detection.
- 🔋 **Optimized for 8GB+ RAM:** Efficient inference buffer management and minimal background battery drain.
- ⌨️ **Global Push-to-Talk:** Press and hold (or tap) global hotkey to transcribe and paste directly into any active app.

---

## 🚀 Quick Install

### Requirements
- Mac with **Apple Silicon** (from M1 or A18 Pro).
- **macOS 14 (Sonoma)** or newer.

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.40/install.sh | /usr/bin/arch -arm64 /bin/bash
```

1. Launch SuperDictate and grant requested permissions: **Microphone**, **Accessibility**, and **Input Monitoring**.
2. Press **Right Command** to begin speaking, and press it again to paste the transcribed text.

---

## ⌨️ Hotkeys & Controls

| Action | Default Hotkey | Behavior |
| :--- | :--- | :--- |
| **Push-to-Talk** | `Right ⌘ (Hold)` | Record while holding, paste on release |
| **Toggle Mode** | `Right ⌘ (Tap)` | Tap to start, tap again to paste |
| **Cancel Dictation** | `Escape` | Discard current recording without pasting |

---

## 🛠️ Build from Source

```bash
# Clone repository
git clone https://github.com/m0rvey/SuperDictate.git
cd SuperDictate

# Build using Swift package manager
swift build -c release
```

---

## 📄 License

Distributed under the **MIT License**. See [LICENSE](../LICENSE) for details.  
Upstream codebase created by [shlgd](https://github.com/shlgd/SuperDictate).
