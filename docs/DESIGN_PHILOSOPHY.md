# SuperDictate Design Philosophy

## 1. Core Principles

### 1.1 100% Local-First & Zero Telemetry
- Dictation happens completely on-device. Speech audio never touches external servers or third-party cloud infrastructure.
- Zero analytics, telemetry, or user tracking.
- The optional AI text-cleanup feature is strictly opt-in (Bring Your Own Key) and communicates directly with the user's chosen provider.

### 1.2 Latency-First User Experience (< 200 ms)
- Dictation must feel immediate. From the millisecond recording stops to the moment text appears in the active application, total elapsed time should be imperceptible.
- Key optimizations supporting this:
  - **Fast Fingerprint Cache**: Eliminates 4–8 second SHA-256 startup verification penalty down to `< 0.2 ms`.
  - **Apple Neural Engine (ANE) Acceleration**: CoreML inference executes on dedicated hardware with minimal CPU/GPU overhead.
  - **Pre-warmed Audio Engine**: Lowers audio tap activation latency.

### 1.3 Memory Efficiency on 8 GB Unified Memory
- Modern Apple Silicon devices (such as the MacBook Neo with A18 Pro, 8 GB RAM) share memory between CPU, GPU, and Neural Engine.
- Memory leaks or idle model bloat degrade overall system responsiveness.
- SuperDictate enforces:
  - Strict `@autoreleasepool` boundaries during transcription.
  - Immediate deallocation of intermediate audio sample buffers upon inference completion.
  - Lifecycle pooling for decoder states.

### 1.4 Native macOS Look and Feel
- Rich modern aesthetics using native macOS APIs (`NSVisualEffectView`, `NSStatusItem`, `CADisplayLink`).
- Full support for ProMotion (60Hz / 120Hz) displays with fluid waveform rendering.
- Dark and Light mode adaptability with seamless glassmorphism.
- True dual-language (RU / EN) native localization across all UI surfaces.

### 1.5 Modular & Resilient Code Architecture
- Code is decomposed into clean, decoupled domain modules with explicit single responsibilities (`Core`, `Audio`, `Speech`, `Text`, `UI`, `Localization`, `Diagnostics`).
- Comprehensive self-testing (`--self-test all`) covers all 24 critical user journeys to prevent regressions.
