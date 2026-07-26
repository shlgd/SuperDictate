# SuperDictate for Intel Mac — Design

## Origin

Fork of [shlgd/SuperDictate](https://github.com/shlgd/SuperDictate) at
`shohart/SuperDictate-Intel`, keeping the GitHub fork relationship so a
pull request back to upstream stays possible if the Intel-support work is
ever accepted there.

## Problem

SuperDictate hard-restricts itself to Apple Silicon in two ways:

1. `install.sh` and `scripts/build-app.sh` explicitly check
   `uname -m == arm64` and refuse to run/build otherwise.
2. Speech recognition uses **FluidAudio** driving the **Parakeet TDT v3**
   model via CoreML, tuned to run on the Apple Neural Engine. Intel Macs
   have no ANE. FluidAudio does expose `.cpuAndGpu`/`.cpuOnly` compute-unit
   modes, but there is no guarantee the ANE-optimized `.mlmodelc` graph
   compiles or performs acceptably without it.

Target hardware for this fork: an Intel Mac Pro, Xeon E5-2678 v3,
**AMD Radeon RX 6600 (Metal 3, 8GB VRAM)**, macOS 15.7.7, Swift 6.1.2 —
reachable over SSH for all real builds/tests (this development environment
is Linux and cannot compile or run macOS/Swift/CoreML code).

## Decision: replace the ASR engine, don't just patch compute units

Given the ANE-tuned model is a real risk on Intel and the user has a
discrete AMD GPU available, the plan swaps the recognition engine instead
of trying to force FluidAudio's ANE model onto CPU/GPU:

**whisper.cpp (ggml), vendored as our own SwiftPM C/C++ target, with
`GGML_METAL` enabled.** whisper.cpp's Metal backend is generic Metal API,
not Apple-Silicon-specific — it will offload matmuls to the RX 6600 via
Metal 3, with Accelerate/BLAS as the CPU fallback path. This was chosen
over:

- Forcing FluidAudio to `.cpuAndGpu`: keeps the ANE-shaped model, unclear
  correctness/perf without real ANE hardware.
- **faster-whisper (CTranslate2/Python)**: CTranslate2 only has CPU and
  CUDA backends — no Metal, no AMD GPU support. On this Mac Pro (no
  NVIDIA GPU) it would run CPU-only, leaving the RX 6600 unused, and it
  would drag a Python runtime into a project that today ships a single
  native binary. Ruled out for this hardware.
- **SwiftWhisper (exPHAT)**, a ready-made SwiftPM wrapper around
  whisper.cpp: unmaintained since May 2024, vendors an old whisper.cpp
  without Metal (CPU+Accelerate only) — would forfeit the GPU entirely.
- **Official `build-xcframework.sh` → binaryTarget**: gets Metal+CoreML
  but adds a whole extra xcodebuild/cmake step ahead of `swift build`,
  breaking the project's "plain `swift build -c release`" pipeline.

Trade-off accepted: vendoring our own whisper.cpp/ggml source snapshot
means we own updating it (pinned commit + an update script), instead of
depending on someone else's package.

## Model

Default: **ggml `large-v3`** (~3 GB), multilingual (needed for Russian,
matching Parakeet v3's multilingual coverage). Chosen over `small`/`medium`
because the user's existing faster-whisper usage on a Linux server with a
large model gives acceptably-accurate, acceptably-fast results, and the
RX 6600 over Metal is expected to make `large-v3` viable on this hardware.
Downloaded at first run from the ggml-org Hugging Face model repo, cached
under `~/Library/Application Support/Whisper/Models`, verified with a
checksum step mirroring the existing `ModelIntegrity` pattern. Model
choice is expected to be revisited once real timings exist on the Mac Pro
— `large-v3-turbo` (~1.6 GB, fewer decoder layers, close accuracy, notably
faster) is the fallback if `large-v3` proves too slow for push-to-talk use.

## Integration surface

The existing code already isolates the ASR engine behind a narrow actor
API in `swift/Sources/Parakey/main.swift` (`TranscriptionWorker`,
`LoadedSpeechEngine` enum, ~line 5179–5320):

```swift
private enum LoadedSpeechEngine {
    case parakeetV3(AsrManager)
}

actor TranscriptionWorker {
    func load(profile:progressHandler:) async throws
    func transcribe(samples:language:requestedAt:) async throws -> TranscriptionWorkerResult
    func warmUp() async throws -> ASRTimingBreakdown
    func unload() async
}
```

The port adds a `whisperLargeV3(WhisperEngine)` case alongside (or
replacing) `.parakeetV3`, with a Swift wrapper (`WhisperEngine`) around the
vendored C API that matches this shape: load model from disk, transcribe
`[Float]` samples at 16kHz mono (same as today) with an optional forced
language, return text + timing breakdown. Everything outside this file
region — hotkeys, history, menu bar UI, permissions, updater, Localization
— is ASR-engine agnostic and stays untouched.

## Build/install changes

- `install.sh`, `scripts/build-app.sh`: accept `x86_64` in addition to
  `arm64`; drop the Rosetta-relaunch logic (not meaningful on real Intel).
- `swift/Package.swift`: drop the FluidAudio dependency (or keep behind a
  flag — TBD in the plan), add the local `whisper_cpp` target and a Swift
  wrapper target.
- No CI changes for Intel: GitHub-hosted macOS runners are Apple Silicon
  only now, so the Intel path cannot be exercised in Actions. All real
  verification happens manually over SSH against the Mac Pro.

## Documentation

Update `README.md`: remove the "Apple Silicon only" restriction, describe
the whisper.cpp + Metal path, correct on-disk model size (460 MB →
~3 GB for `large-v3`), and add a note that Intel support is unverified by
CI and relies on manual testing.

## Testing plan

All real compilation and execution happens over SSH on the Mac Pro
(192.168.1.246, user `shohart`):

1. `swift build -c release --package-path swift` succeeds on `x86_64`.
2. `swift run -c debug --package-path swift Parakey --self-test all` passes.
3. `./scripts/build-app.sh` produces a signed (ad-hoc) `.app`; `codesign
   --verify --deep --strict` passes.
4. Manual smoke test: launch the app, grant permissions, record a short
   phrase via the push-to-talk hotkey, confirm transcription + paste.
5. Benchmark: force CPU-only vs Metal compute path for the same recording
   to confirm the expected GPU speedup on the RX 6600, and to decide
   between `large-v3` and `large-v3-turbo` for the shipped default.

## Out of scope

- Universal (arm64 + x86_64) binary in one build — this fork targets
  Intel; keeping Apple Silicon working via FluidAudio at the same time
  would double the engine-abstraction surface for no user benefit here.
- Notarization / Developer ID signing — unchanged from upstream (ad-hoc
  signing only).
- Any UI/hotkey/history feature changes — strictly an ASR-engine and
  build-gate swap.
