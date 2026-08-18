// Parakey — push-to-talk dictation for macOS Apple Silicon.
// main.swift

import AppKit
import Foundation

#if DEBUG
if let status = ParakeySelfTest.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
#endif

let app = NSApplication.shared
let launchArguments = Array(CommandLine.arguments.dropFirst())

if let diagnosticResult = runAudioCaptureDiagnostic(arguments: launchArguments) {
    exit(diagnosticResult)
} else if launchArguments.first == RECORDING_HUD_EXPORT_ARGUMENT {
    guard launchArguments.count == 2 else {
        fputs("usage: SuperDictate --export-hud-animation <frames-directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportRecordingHUDAnimationFrames(to: URL(fileURLWithPath: launchArguments[1],
                                                       isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("HUD export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if let launch = UpdateProgressLaunch(arguments: launchArguments) {
    let delegate = UpdateProgressAppDelegate(launch: launch)
    app.delegate = delegate
    app.run()
} else if launchArguments.contains(AGENT_ARGUMENT) {
    app.setActivationPolicy(.accessory)
    let delegate = ParakeyApp()
    app.delegate = delegate
    refuseHostileRegistryEnvironmentAndExit()
    app.run()
} else {
    let delegate = SuperDictateControlPanelApp()
    app.delegate = delegate
    app.run()
}
