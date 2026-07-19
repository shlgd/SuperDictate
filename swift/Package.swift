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
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "313feb4bd692780a9a5b5fa9048fdb119486dde8"),
    ],
    targets: [
        .executableTarget(
            name: "Parakey",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
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
    ]
)
