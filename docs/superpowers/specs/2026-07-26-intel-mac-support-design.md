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

Given the ANE-tuned model is a real risk on Intel, the plan swaps the
recognition engine instead of trying to force FluidAudio's ANE model onto
CPU/GPU. The engine is **whisper.cpp (ggml), vendored as our own SwiftPM
C/C++ target, CPU-only (Accelerate/BLAS backend)**. This was chosen over:

- Forcing FluidAudio to `.cpuAndGpu`: keeps the ANE-shaped model, unclear
  correctness/perf without real ANE hardware.
- **faster-whisper (CTranslate2/Python)**: CTranslate2 only has CPU and
  CUDA backends — no Metal, no AMD GPU support. It would drag a Python
  runtime into a project that ships a single native binary. Ruled out.
- **SwiftWhisper (exPHAT)**, a ready-made SwiftPM wrapper around
  whisper.cpp: unmaintained since May 2024, vendors an old whisper.cpp
  snapshot. With Metal off the table (see below) its staleness is now the
  only real demerit versus vendoring our own — vendoring was still chosen
  for control over the pinned commit and update path.
- **Official `build-xcframework.sh` → binaryTarget**: adds a whole extra
  xcodebuild/cmake step ahead of `swift build`. Not needed once Metal is
  out of scope.
- **whisper.cpp's built-in Parakeet-TDT support** (`examples/parakeet-cli`,
  merged into ggml very recently): tempting, since it's the *same* model
  FluidAudio uses today, just running on ggml instead of CoreML/ANE. Ruled
  out — see the Metal/GPU finding below.

### Why Metal is off, with evidence

The spec originally called for `GGML_METAL=ON` to use the Mac Pro's AMD
Radeon RX 6600 (Metal 3). This was tested for real over SSH before writing
the implementation plan, per-advisor:

- Built whisper.cpp from source (plain `cmake`/`make`, not yet SwiftPM) on
  the Mac Pro with `GGML_METAL=ON`.
- `parakeet-cli` (ggml's native Parakeet TDT v3 support), loading the
  official `ggml-org/parakeet-GGUF` conversion, fails right after model
  load — but not consistently the same way. A bare run (both with Metal
  and with `-ng`/CPU-only) **segfaults** (SIGSEGV, exit 139); the macOS
  crash report shows `EXC_BAD_ACCESS`/`KERN_INVALID_ADDRESS` at a faulting
  address adjacent to the stack region — consistent with a stack overflow,
  not heap corruption. Running the identical command under `lldb`
  produces a *different* outcome: a caught C++ exception
  (`exception during model load: vector`) and a clean exit(1) instead of a
  crash — most likely because the debugger session has different stack
  limits than the bare SSH shell. Two related open upstream issues,
  [#3932](https://github.com/ggml-org/whisper.cpp/issues/3932) and
  [#3933](https://github.com/ggml-org/whisper.cpp/issues/3933), describe
  unvalidated-input / uncaught-exception bugs in this exact loader
  (`src/parakeet.cpp`, mel-cache init and duration decoding) — neither
  matches our crash exactly (both are about crafted/malicious model
  files, ours is the vendor's own official model), but they corroborate
  that this integration, merged only days before this investigation, is
  still being shaken out. Conclusion: too new/unstable to ship, regardless
  of the GPU question. Not investigated further — this dependency was
  already rejected on the Metal-correctness grounds below, and root-causing
  someone else's in-flight bug is out of scope here.
- `whisper-cli` with Metal enabled, on `ggml-base.en.bin`, transcribing
  the standard `jfk.wav` sample: **produced wrong text** —
  `"verynown, I, a of"` instead of the correct transcript — and took
  2.7s total versus 1.5s for the identical run with `-ng` (CPU-only,
  which produced the correct transcript). The Metal log shows
  `simdgroup matrix mul. = false` and `has unified memory = false` for
  this GPU — ggml's Metal backend is hitting an under-exercised fallback
  path on non-Apple-Silicon/AMD hardware, and that path is both wrong and
  slower here.

Conclusion: Metal is not merely unnecessary, it is actively broken on this
GPU. The build is **CPU-only**: `GGML_METAL=OFF`, CPU backend +
Accelerate/BLAS. This also removes the entire "can SwiftPM compile
`.metal` shaders" question the original spec left open — there is no
Metal source to compile, no bundle-resource lookup, no
`GGML_METAL_EMBED_LIBRARY` mechanism to reproduce outside CMake.

## Model

Default: **ggml `large-v3-turbo`** (~1.6 GB). Chosen from real CPU-only
benchmarks run on the Mac Pro (Xeon E5-2678 v3, 24 threads), transcribing
a ~9.4s Russian sample (macOS `say -v Milena` synthesized speech) — all
three candidates below produced accurate Russian text:

| Model | Size on disk | Total time (9.4s clip) | Real-time factor |
|---|---|---|---|
| `small` | 487 MB | 9.1 s | ~1.0x |
| `medium` | 1.5 GB | 12.7 s | ~1.35x |
| `large-v3-turbo` | 1.6 GB | 9.8 s | ~1.0x |

`large-v3-turbo`'s reduced decoder makes it match `small`'s speed on this
CPU while giving `large-v3`-level accuracy; `medium` is strictly dominated
(slower, and generally rated less accurate than turbo) and is not used.
Forcing greedy decoding (`-bo 1 -bs 1`) instead of the default beam-5
search did not meaningfully change turbo's timing — encode time, not
decode/search, dominates on this hardware, so decode strategy is left at
whisper.cpp's default. Downloaded at first run from the `ggml-org`
Hugging Face model repo (pinned revision, not `main`), cached under
`~/Library/Application Support/Whisper/Models`, verified with a checksum
step mirroring the existing `ModelIntegrity` pattern.

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
2. `swift run -c debug --package-path swift Parakey --self-test all` passes
   (including the FluidAudio/Parakeet-shaped assertions and cache-path
   tests, updated for the new engine — see the plan).
3. `./scripts/build-app.sh` produces a signed (ad-hoc) `.app`; `codesign
   --verify --deep --strict` passes.
4. Manual smoke test: launch the app, grant permissions, record a short
   phrase via the push-to-talk hotkey, confirm transcription + paste.
5. Real-hardware benchmark already performed during design (see Model
   section above) — no further Metal-vs-CPU comparison needed.

## Out of scope

- Universal (arm64 + x86_64) binary in one build — this fork targets
  Intel; keeping Apple Silicon working via FluidAudio at the same time
  would double the engine-abstraction surface for no user benefit here.
- Notarization / Developer ID signing — unchanged from upstream (ad-hoc
  signing only).
- Any UI/hotkey/history feature changes — strictly an ASR-engine and
  build-gate swap.
