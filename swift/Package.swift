// swift-tools-version: 6.0
//
// SuperDictate — a Swift push-to-talk dictation app
// for macOS Apple Silicon. Native AppKit / AVFoundation, FluidAudio
// driving Parakeet TDT v3 on the Apple Neural Engine. macOS 14
// (Sonoma) minimum. The Hardened Runtime microphone entitlement
// (`com.apple.security.device.audio-input` in `entitlements.plist`)
// is what Tahoe 26 checks before exposing the app in Privacy &
// Security → Microphone; on macOS 14–25 the legacy sandbox key
// (`com.apple.security.device.microphone`) is the fallback. Both
// ship in the same build so a single notarised binary works
// across the supported range.
import PackageDescription

let package = Package(
    name: "Parakey",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .executable(name: "Parakey", targets: ["Parakey"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "whisper_cpp",
            exclude: [
                "ggml-cpu/arch/arm",
                "ggml-cpu/arch/riscv",
                "ggml-cpu/arch/powerpc",
                "ggml-cpu/arch/s390",
                "ggml-cpu/arch/wasm",
                "ggml-cpu/arch/loongarch",
                "ggml-cpu/spacemit",
            ],
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_VERSION", to: "\"080bbbe8\""),
                .define("GGML_COMMIT", to: "\"080bbbe85230f624f0b52127f1ae1218247989f9\""),
                .define("WHISPER_VERSION", to: "\"080bbbe8\""),
                .headerSearchPath("."),
                .headerSearchPath("ggml-cpu"),
                .unsafeFlags(["-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2"]),
            ],
            cxxSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_VERSION", to: "\"080bbbe8\""),
                .define("GGML_COMMIT", to: "\"080bbbe85230f624f0b52127f1ae1218247989f9\""),
                .define("WHISPER_VERSION", to: "\"080bbbe8\""),
                .headerSearchPath("."),
                .headerSearchPath("ggml-cpu"),
                .unsafeFlags(["-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "Parakey",
            dependencies: ["whisper_cpp"]
            // No `resources:` here on purpose. SwiftPM bundles them as
            // a `<Package>_<Target>.bundle` directory next to the
            // executable, which `codesign --deep` won't accept as a
            // signable component because it lacks Info.plist. Instead,
            // the menubar PNGs are copied into Contents/Resources/ by
            // dev-run.sh and ship-swift.sh — the canonical .app layout
            // where Bundle.main finds them via the standard search
            // path. Source PNGs live in swift/Resources/ at the repo
            // root, NOT in the SwiftPM target, so SwiftPM never sees them.
        ),
    ],
    cLanguageStandard: .c17,
    cxxLanguageStandard: .cxx17
)
