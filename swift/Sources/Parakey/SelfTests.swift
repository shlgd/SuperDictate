// Debug-only self-tests for SuperDictate's platform and pure-logic behavior.
// Keeping these declarations outside main.swift makes the runtime entry point
// easier to navigate while preserving the existing `--self-test` interface.

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

#if DEBUG
enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum ParakeySelfTest {
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[0] == "--self-test" else { return nil }
        guard arguments.count == 2 else { return fail("usage") }

        switch arguments[1] {
        case "hotkey":
            return runSuite("hotkey", testHotkey)
        case "readiness":
            return runSuite("readiness", testReadiness)
        case "paste":
            return runSuite("paste", testPasteSuffixFormatting)
        case "history":
            return runSuite("history", testRecentTranscriptLimit)
        case "statistics":
            return runSuite("statistics", testDictationUsageStatistics)
        case "corrections":
            return runSuite("corrections", testTranscriptCorrections)
        case "fillers":
            return runSuite("fillers", testFillerWordRemoval)
        case "audio-level":
            return runSuite("audio-level", testAudioLevelMetering)
        case "audio-conversion":
            return runSuite("audio-conversion", testAudioConversion)
        case "audio-input":
            return runSuite("audio-input", testAudioInputDeviceFiltering)
        case "model-status":
            return runSuite("model-status", testSpeechModelStartupStatus)
        case "audio-route":
            return runSuite("audio-route", testAudioRouteChangeDecision)
        case "recording-lifecycle":
            return runSuite("recording-lifecycle", testRecordingLifecycle)
        case "power-state":
            return runSuite("power-state", testPowerStateRecoveryDecision)
        case "model-integrity":
            return runSuite("model-integrity", testModelIntegrity)
        case "update":
            return runSuite("update", testUpdate)
        case "hostile-env":
            return runSuite("hostile-env", testHostileRegistryEnvDetection)
        case "logging":
            return runSuite("logging", testPrivateLogAppend)
        case "diagnostics":
            return runSuite("diagnostics", testDiagnostics)
        case "insertion-target":
            return runSuite("insertion-target", testInsertionTargetTracking)
        case "insertion-target-live":
            return runSuite("insertion-target-live", testLiveInsertionTargetProbe)
        case "all":
            return runSuite("all", testAll)
        default:
            return fail("unknown")
        }
    }

    private static func runSuite(_ name: String, _ body: () throws -> Void) -> Int32 {
        do {
            try body()
            print("PASS \(name)")
            return EXIT_SUCCESS
        } catch {
            print("FAIL \(name): \(error)")
            return EXIT_FAILURE
        }
    }

    private static func fail(_ message: String) -> Int32 {
        print("FAIL self-test: \(message)")
        return EXIT_FAILURE
    }

    private static func testAll() throws {
        try testHotkey()
        try testReadiness()
        try testPasteSuffixFormatting()
        try testRecentTranscriptLimit()
        try testDictationUsageStatistics()
        try testTranscriptCorrections()
        try testFillerWordRemoval()
        try testAudioLevelMetering()
        try testAudioConversion()
        try testAudioInputDeviceFiltering()
        try testSpeechModelStartupStatus()
        try testAudioRouteChangeDecision()
        try testRecordingLifecycle()
        try testPowerStateRecoveryDecision()
        try testModelIntegrity()
        try testUpdate()
        try testHostileRegistryEnvDetection()
        try testPrivateLogAppend()
        try testDiagnostics()
        try testInsertionTargetTracking()
    }

    private static func testInsertionTargetTracking() throws {
        func target(pid: pid_t, window: UInt, element: UInt) -> FocusedInsertionTargetFrame {
            FocusedInsertionTargetFrame(
                frame: NSRect(x: 100, y: 100, width: 2, height: 18),
                visualFrame: NSRect(x: 80, y: 80, width: 300, height: 48),
                resolutionKind: "self-test",
                identity: FocusedInsertionTargetIdentity(
                    applicationPID: pid,
                    windowToken: window,
                    elementToken: element
                )
            )
        }

        let first = target(pid: 10, window: 1, element: 1)
        let secondField = target(pid: 10, window: 1, element: 2)
        let otherApp = target(pid: 20, window: 2, element: 1)
        var stabilizer = RecordingHUDTargetStabilizer()
        stabilizer.reset(initialApplicationPID: 10)

        switch stabilizer.observe(first) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "initial target from the starting app should be accepted immediately")
        default:
            throw SelfTestFailure.failed("initial insertion target was not accepted")
        }

        switch stabilizer.observe(first) {
        case .update(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "the confirmed insertion target should update without another switch")
        default:
            throw SelfTestFailure.failed("confirmed insertion target did not produce an update")
        }

        if case .none = stabilizer.observe(secondField) {
            // Expected: a new field in the same app needs two matching observations.
        } else {
            throw SelfTestFailure.failed("same-app target switched without confirmation")
        }
        switch stabilizer.observe(secondField) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: secondField.identity,
                       "same-app target should switch after confirmation")
        default:
            throw SelfTestFailure.failed("same-app target did not switch after confirmation")
        }

        for attempt in 1...2 {
            if case .none = stabilizer.observe(otherApp) {
                continue
            }
            throw SelfTestFailure.failed("cross-app target switched on observation \(attempt)")
        }
        switch stabilizer.observe(otherApp) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: otherApp.identity,
                       "cross-app target should switch after three stable observations")
        default:
            throw SelfTestFailure.failed("cross-app target did not switch after confirmation")
        }

        if case .none = stabilizer.observe(nil) {
            // A missing AX sample must not discard the confirmed target.
        } else {
            throw SelfTestFailure.failed("missing target unexpectedly changed HUD ownership")
        }
        switch stabilizer.observe(otherApp) {
        case .update:
            break
        default:
            throw SelfTestFailure.failed("confirmed target was lost after one missing AX sample")
        }

        let screen = InsertionTargetScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_055)
        )
        let context = InsertionTargetQueryContext(
            applicationPID: 10,
            applicationName: "self-test",
            bundleIdentifier: "self-test",
            screens: [screen],
            coordinateReferenceMaxY: screen.frame.maxY,
            lastClickPoint: nil
        )
        let documentFrame = NSRect(x: 560, y: 150, width: 946, height: 698)
        let caretFrame = NSRect(x: 582, y: 419, width: 2, height: 17)
        let documentVisualFrame = FocusedInsertionTargetLocator.visualTargetFrame(
            elementFrame: documentFrame,
            caretFrame: caretFrame,
            context: context
        )
        try expect(documentVisualFrame.minX, equals: documentFrame.minX,
                   "large editors should retain their block's left edge")
        try expect(documentVisualFrame.minY, equals: caretFrame.minY,
                   "large editors should anchor vertically to the caret line")
        try expect(documentVisualFrame.height, equals: caretFrame.height,
                   "large editors should not place the HUD above the whole document")

        let compactFrame = NSRect(x: 700, y: 120, width: 720, height: 96)
        try expect(
            FocusedInsertionTargetLocator.visualTargetFrame(
                elementFrame: compactFrame,
                caretFrame: NSRect(x: 720, y: 150, width: 2, height: 18),
                context: context
            ),
            equals: compactFrame,
            "compact composers should keep the HUD above the whole input block"
        )
    }

    private static func testLiveInsertionTargetProbe() throws {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SelfTestFailure.failed("frontmost application unavailable")
        }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let context = InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: screens.first?.frame.maxY ?? 0,
            lastClickPoint: nil
        )
        let result = FocusedInsertionTargetLocator.query(context: context)
        try expect(result.applicationPID, equals: app.processIdentifier,
                   "live target query should preserve the requested application")
        try expect(result.diagnostic.isEmpty, equals: false,
                   "live target query should always explain its result")
        let targetSummary = result.target.map {
            "\($0.resolutionKind) frame=\(NSStringFromRect($0.frame)) visual=\(NSStringFromRect($0.visualFrame))"
        } ?? "unavailable"
        print("AX_PROBE \(result.applicationName) (\(result.bundleIdentifier)): \(targetSummary); \(result.diagnostic)")
    }

    private static func testPrivateLogAppend() throws {
        try expect(
            privacySafeLogPath("/Users/example/Documents/Parakey Diagnostics.txt"),
            equals: "Parakey Diagnostics.txt",
            "log path labels should omit parent directories"
        )
        try expect(
            privacySafeLogPath("/"),
            equals: "<local path>",
            "log path labels should fall back when no filename is available"
        )
        try expect(
            privacySafeBundlePath("/Applications/SuperDictate.app"),
            equals: "/Applications/SuperDictate.app",
            "bundle path labels should keep the canonical install path"
        )
        try expect(
            privacySafeBundlePath("/Users/example/Downloads/SuperDictate.app"),
            equals: "SuperDictate.app",
            "bundle path labels should omit parent directories for nonstandard installs"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-log-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("SuperDictate.log")
        try appendPrivateLogData(Data("one\n".utf8), to: logFile)
        try appendPrivateLogData(Data("two\n".utf8), to: logFile)

        let attrs = try fm.attributesOfItem(atPath: logFile.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        try expect(permissions & 0o777,
                   equals: 0o600,
                   "log file should be private to the current user")
        try expect(
            String(data: try Data(contentsOf: logFile), encoding: .utf8),
            equals: "one\ntwo\n",
            "log appends should preserve existing content"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("target\n".utf8).write(to: target)
        let link = root.appendingPathComponent("link.log")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        var symlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: link)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "log appends should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "log symlink rejection should leave the target untouched"
        )

        let hardlinkTarget = root.appendingPathComponent("hardlink-target.log")
        try Data("hardlink target\n".utf8).write(to: hardlinkTarget)
        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(hardlinkTarget.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }

        var hardlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: hardlink)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected,
                   equals: true,
                   "log appends should reject hard-linked files")
        try expect(
            String(data: try Data(contentsOf: hardlinkTarget), encoding: .utf8),
            equals: "hardlink target\n",
            "log hard-link rejection should leave the target untouched"
        )
    }

    private static func testDiagnostics() throws {
        let transcriptSecret = "secret dictated phrase 58A03D"
        let correctionSecret = "private correction replacement 9F42"
        let report = diagnosticsReportText(
            from: DiagnosticsReportSnapshot(
                generated: "2026-05-28T10:00:00Z",
                appVersion: "9.8.7",
                appBuild: "123",
                macOS: "Version 26.0",
                bundleID: "com.local.superdictate",
                bundlePath: "/Applications/SuperDictate.app",
                installKind: "Applications app",
                status: "Hold Right Option to dictate",
                startup: "Runtime ready",
                speechModelReady: true,
                coreRuntimeReady: true,
                readyForDictation: true,
                recordingActive: false,
                transcribing: false,
                memoryLines: ["Resident: 100 MB"],
                permissionLines: ["Microphone: granted", "Accessibility: granted", "Input Monitoring: granted"],
                settingLines: [
                    "Speech model: Multilingual (Parakeet TDT v3)",
                    "Language: Auto-detect",
                    "Recent transcripts: Last 5 (1 in memory)",
                    "Text corrections: 1 configured",
                    "Text correction sync: configured",
                ],
                updateLines: ["Pending update: none"],
                microphoneLines: ["Selected: System default", "Available inputs: none reported"],
                logPath: "~/Library/Logs/SuperDictate.log",
                recentLogLines: ["[10:00:00] release: 1.23 s captured, transcribing"]
            )
        )
        try expect(report.contains(transcriptSecret), equals: false,
                   "diagnostics report should not include transcript contents")
        try expect(report.contains(correctionSecret), equals: false,
                   "diagnostics report should not include text correction contents")
        try expect(report.contains("Text corrections: 1 configured"), equals: true,
                   "diagnostics report should include correction counts")
        try expect(report.contains("Speech model: Multilingual (Parakeet TDT v3)"), equals: true,
                   "diagnostics report should include the speech model")
        try expect(report.contains("Recent log lines:"), equals: true,
                   "diagnostics report should include the recent log section")
        try expect(report.contains("Privacy: transcript text and text-correction contents are not included."),
                   equals: true,
                   "diagnostics report should state the privacy boundary")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("SuperDictate.log")
        for line in 1...6 {
            try appendPrivateLogData(Data("[10:00:0\(line)] line \(line)\n".utf8), to: logFile)
        }
        try expect(
            try recentDiagnosticLogLines(from: logFile, maxBytes: 4096, maxLines: 3),
            equals: ["[10:00:04] line 4", "[10:00:05] line 5", "[10:00:06] line 6"],
            "diagnostic log tail should return the newest bounded lines"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("[10:00:00] target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink.log")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: symlink, maxBytes: 4096, maxLines: 3)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "diagnostic log tail should reject leaf symlinks")

        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(target.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }
        var hardlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: hardlink, maxBytes: 4096, maxLines: 3)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected, equals: true,
                   "diagnostic log tail should reject hard-linked files")
    }

    private static func testHotkey() throws {
        try testHotkeyPreferenceNormalization()
        try testHotkeyPreferenceUpdateResults()
        try testHotkeyRecorderRestartActions()
        try testHandledHotkeySuppression()
        try testFKeyAutoRepeatSuppressesWithoutAction()
        try testRightModifierReleaseWithLeftFlagStillSet()
        try testHistoryChordShowsOverlay()
        try testOptionCommandEnterChordStopsWithEnter()
        try testEnterShortcutModeSelection()
        try testTogglePressFlipsOnceAndReleaseIsNoOp()
        try testToggleGatedPressDoesNotFlipToggleState()
        try testEscapePassesThroughWhenNotRecording()
        try testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording()
    }

    private static func testHotkeyPreferenceNormalization() throws {
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(DEFAULT_HOTKEY_KEYCODE))),
            equals: DEFAULT_HOTKEY_KEYCODE,
            "stored hotkey normalization should keep supported numeric keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: " 96\n"),
            equals: CGKeyCode(96),
            "stored hotkey normalization should accept legacy string keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 98)),
            equals: CGKeyCode(98),
            "stored hotkey normalization should accept recorded F-key keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(98)),
            equals: HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil),
            "recorded F-key choices should get a stable display name"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 999)),
            equals: nil,
            "stored hotkey normalization should reject unsupported keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: -1)),
            equals: nil,
            "stored hotkey normalization should reject negative keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(999)),
            equals: hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE),
            "unknown hotkey choices should fall back to the default"
        )

        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98)),
            equals: .accept(HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept F-key presses outside the quick-pick list"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 0)),
            equals: .reject("Choose a right-side modifier key or an F-key. Typing keys are not safe because Parakey suppresses its dictation key globally."),
            "hotkey recorder should reject typing keys"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98, isAutoRepeat: true)),
            equals: .ignore,
            "hotkey recorder should ignore auto-repeat"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.flagsChanged,
                                               keycode: 61,
                                               flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .accept(HotkeyChoice(name: "Right Option",
                                         keycode: 61,
                                         isModifier: true,
                                         modifierFlag: .maskAlternate)),
            "hotkey recorder should accept right-side modifier presses"
        )
    }

    private static func testHotkeyPreferenceUpdateResults() throws {
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)
        let invalid = HotkeyChoice(name: "A", keycode: 0, isModifier: false, modifierFlag: nil)

        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persistedKeycode: f7.keycode
            ),
            equals: .saved(f7),
            "hotkey preference update should save supported keys after persistence confirms them"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: invalid,
                previous: f5,
                persistedKeycode: f5.keycode
            ),
            equals: .rejected("That key cannot be used for dictation."),
            "hotkey preference update should reject unsupported keys before mutating settings"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persistedKeycode: f5.keycode
            ),
            equals: .rolledBack(
                previous: f5,
                message: "Parakey could not save that hotkey, so it kept F5."
            ),
            "hotkey preference update should roll back when persisted settings disagree"
        )
    }

    private static func testHotkeyRecorderRestartActions() throws {
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: false,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not start a listener that was not active"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: true,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not restart the listener during termination"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: true
            ),
            equals: .restoredListener,
            "hotkey recorder should treat a successful restart as recovered"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .recordFailure,
            "hotkey recorder should surface restart failure after an active listener was paused"
        )
    }

    private static func testReadiness() throws {
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: false,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "not-ready app without core runtime should wait and rebuild only"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.microphone]),
            equals: .blockForPermissions([.microphone]),
            "core-ready app with missing microphone should block"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.accessibility]),
            equals: .blockForPermissions([.accessibility]),
            "ready app with missing accessibility should block"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .startHotkeyListener,
            "core-ready app with all permissions should start hotkey"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "ready app with all permissions should remain ready and rebuild only"
        )

        try expect(
            productionSpeechModelProfile(rawValue: nil),
            equals: .multilingualV3,
            "missing speech model setting should use the production default"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.multilingualV3.rawValue),
            equals: .multilingualV3,
            "stored v3 speech model should remain valid"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.englishUnified.rawValue),
            equals: .multilingualV3,
            "deprecated Unified speech model setting should migrate back to v3"
        )
        try expect(
            productionSpeechModelProfile(rawValue: "unknown_model"),
            equals: .multilingualV3,
            "unknown speech model setting should migrate back to v3"
        )

        try expect(
            speechModelSetupRowState(profile: .multilingualV3,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: true,
                                     startupStatusTitle: "Downloading speech model… 50%",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Downloading speech model… 50%",
                                           status: "Loading",
                                           buttonTitle: nil),
            "setup checklist should show speech model progress"
        )
        try expect(
            speechModelSetupRowState(profile: .multilingualV3,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: StartupFailure(stage: .speechModel, detail: "download failed")),
            equals: SetupChecklistRowState(detail: "download failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for speech model failures"
        )
        try expect(
            speechModelSetupRowState(profile: .multilingualV3,
                                     isSpeechModelReady: true,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Parakeet TDT v3 is loaded locally.",
                                           status: "Ready",
                                           buttonTitle: nil),
            "setup checklist should show the speech model when ready"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: true,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: false,
                                    failure: StartupFailure(stage: .audioInput, detail: "no input device")),
            equals: SetupChecklistRowState(detail: "no input device",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for audio input failures"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: false,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: true,
                                    failure: nil),
            equals: SetupChecklistRowState(detail: "Available after the speech model loads.",
                                           status: "Waiting",
                                           buttonTitle: nil),
            "setup checklist should not start audio before the speech model is ready"
        )
        try expect(
            hotkeySetupRowState(isReady: false,
                                hotkeyTestSucceeded: false,
                                triggerMode: .hold,
                                hotkeyName: "Right Option",
                                failure: StartupFailure(stage: .hotkeyListener, detail: "event tap failed")),
            equals: SetupChecklistRowState(detail: "event tap failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for hotkey listener failures"
        )
        try expect(
            hotkeySetupRowState(isReady: true,
                                hotkeyTestSucceeded: true,
                                triggerMode: .toggle,
                                hotkeyName: "F5",
                                failure: nil),
            equals: SetupChecklistRowState(detail: "Press F5 to dictate.",
                                           status: "Detected",
                                           buttonTitle: nil),
            "setup checklist should show detected hotkey state"
        )

        try expect(
            previousExitNoticeAction(previousRunWasActive: false),
            equals: .none,
            "clean previous exits should not show the abnormal-exit notice"
        )
        try expect(
            previousExitNoticeAction(previousRunWasActive: true),
            equals: .showNotice,
            "active run markers should show the abnormal-exit notice on next launch"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "SHA-256 mismatch").contains("Reset Speech Model Cache"),
            equals: true,
            "speech model integrity failures should point to cache reset"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "download timed out").contains("audio is not uploaded"),
            equals: true,
            "speech model download failures should preserve the local-audio privacy boundary"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "Free some disk space, then retry loading the speech model."),
            equals: "Free some disk space, then retry loading the speech model.",
            "disk-space failures should not add unrelated reset-cache guidance"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, errorDescription: "no input device"),
            equals: "no input device",
            "non-model startup failures should keep their original detail"
        )

        let coreAudioStopError = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: 1_937_010_544,
            userInfo: ["failed call": "PerformCommand(*ioNode, kAUStartIO, NULL, 0)"]
        )
        let coreAudioErrorDescription = audioStartupErrorDescription(coreAudioStopError)
        try expect(
            coreAudioErrorDescription.contains("OSStatus 1937010544"),
            equals: true,
            "CoreAudio startup errors should include the decimal OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("0x73746f70"),
            equals: true,
            "CoreAudio startup errors should include the hex OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("'stop'"),
            equals: true,
            "CoreAudio startup errors should include printable four-character codes"
        )
        try expect(
            coreAudioErrorDescription.contains("PerformCommand(*ioNode, kAUStartIO, NULL, 0)"),
            equals: true,
            "CoreAudio startup errors should preserve the failed AVFAudio call"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, error: coreAudioStopError).contains("restart CoreAudio"),
            equals: true,
            "exhausted CoreAudio startup failures should give OS recovery guidance"
        )
    }

    private static func testPasteSuffixFormatting() throws {
        try expect(
            pastedText(from: "hello world", suffix: .appendSpace),
            equals: "hello world ",
            "append-space suffix should preserve the existing default"
        )
        try expect(
            pastedText(from: "hello world", suffix: .none),
            equals: "hello world",
            "no suffix should paste corrected transcript unchanged"
        )
        try expect(
            pastedText(from: "hello world", suffix: .appendNewline),
            equals: "hello world\n",
            "append-newline suffix should add a single newline"
        )
        try expect(
            pastedText(from: "hello world ", suffix: .appendSpace),
            equals: "hello world  ",
            "suffix formatting should not trim or rewrite corrected text"
        )
        try expect(
            TextInserter.defaultStrategy,
            equals: .clipboardPaste,
            "clipboard paste should remain the default insertion strategy"
        )
        try expect(
            textInsertionStrategyChain(primary: .clipboardPaste),
            equals: [.clipboardPaste, .directUnicode],
            "clipboard paste should fall back to direct Unicode insertion"
        )
        try expect(
            textInsertionStrategyChain(primary: .directUnicode),
            equals: [.directUnicode],
            "direct Unicode insertion should not loop back to clipboard paste"
        )
        try expect(
            TextInserter.defaultStrategyDescription,
            equals: "Clipboard paste with Direct Unicode typing fallback",
            "diagnostics should describe the insertion fallback chain"
        )
        let unicodeChunks = unicodeInsertionChunks(for: "ab👩‍💻cd", maxUTF16UnitsPerEvent: 4)
            .map { String(decoding: $0, as: UTF16.self) }
        try expect(
            unicodeChunks,
            equals: ["ab", "👩‍💻", "cd"],
            "direct Unicode insertion should keep extended grapheme clusters together while chunking"
        )
        try expect(
            unicodeInsertionChunks(for: "abc", maxUTF16UnitsPerEvent: 0),
            equals: [],
            "direct Unicode chunking should reject invalid chunk sizes"
        )
        try expect(
            clipboardPasteKeyboardEventSteps(commandKey: 0x37, pasteKey: 0x09),
            equals: [
                KeyboardEventStep(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: false, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x37, keyDown: false, flags: []),
            ],
            "clipboard paste should synthesize a full Command+V key sequence"
        )

        let pasteboardProbe = MainActor.assumeIsolated {
            let pasteboardName = NSPasteboard.Name("com.local.superdictate.self-test.\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: pasteboardName)
            let wrote = ClipboardPasteInserter.write("pasteboard probe", to: pasteboard)
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            _ = ClipboardPasteInserter.write("temporary dictation", to: pasteboard)
            snapshot.restore(to: pasteboard)
            return (wrote: wrote, stored: pasteboard.string(forType: .string))
        }
        try expect(
            pasteboardProbe.wrote,
            equals: true,
            "clipboard paste should report pasteboard write success"
        )
        try expect(
            pasteboardProbe.stored,
            equals: "pasteboard probe",
            "clipboard paste should write the intended string before posting Cmd+V"
        )
    }

    private static func testRecentTranscriptLimit() throws {
        let transcripts = ["newest", "second", "third", "fourth", "fifth", "sixth"]

        try expect(
            limitedRecentTranscripts(transcripts, limit: .off),
            equals: [],
            "off should keep no recent transcripts"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last1),
            equals: ["newest"],
            "last-one history should keep only the newest transcript"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last5),
            equals: ["newest", "second", "third", "fourth", "fifth"],
            "last-five history should preserve the current default cap"
        )
        try expect(
            parseRecentTranscriptLimit(storedValue: NSNumber(value: 1)),
            equals: .last1,
            "numeric defaults writes should be accepted for last-one history"
        )

        let timedEntries = transcripts.enumerated().map { index, text in
            TranscriptHistoryEntry(
                text: text,
                transcriptionDurationSeconds: Double(index + 1) / 10
            )
        }
        try expect(
            limitedRecentTranscriptEntries(timedEntries, limit: .last1),
            equals: [TranscriptHistoryEntry(text: "newest", transcriptionDurationSeconds: 0.1)],
            "history trimming should preserve transcription timing metadata"
        )

        let archivedEntries = limitedTranscriptHistoryArchive(timedEntries, maximumCount: 6)
        try expect(
            archivedEntries.count,
            equals: 6,
            "the archive should retain entries beyond the visible history limit"
        )
        let archiveAfterDeletion = transcriptHistoryArchive(archivedEntries, removing: 2)
        try expect(
            limitedRecentTranscriptEntries(archiveAfterDeletion, limit: .last5).map(\.text),
            equals: ["newest", "second", "fourth", "fifth", "sixth"],
            "deleting a visible history entry should backfill it from the archive"
        )
        try expect(
            transcriptHistoryArchive(archivedEntries, removing: 99),
            equals: archivedEntries,
            "an invalid history deletion index should leave the archive unchanged"
        )

        let historyRowHitTargets = MainActor.assumeIsolated { () -> (delete: Bool, row: Bool, deleteAction: Bool, copyAction: Bool) in
            let row = HistoryTranscriptItemView(
                transcript: "test",
                preview: "test",
                transcriptionDurationSeconds: 0.1,
                asrTiming: nil,
                historyIndex: 0,
                target: nil,
                action: NSSelectorFromString("noop:"),
                onDelete: { _ in }
            )
            row.frame = NSRect(x: 0, y: 0, width: 600, height: 56)
            guard let deleteButton = row.subviews.compactMap({ $0 as? HistoryDeleteButton }).first else {
                return (false, false, false, false)
            }
            deleteButton.frame = NSRect(x: 560, y: 14, width: 28, height: 28)
            let deleteAction: Bool
            if case .delete(0) = row.hitAction(atWindowPoint: NSPoint(x: 574, y: 28)) {
                deleteAction = true
            } else {
                deleteAction = false
            }
            let copyAction: Bool
            if case .copy("test") = row.hitAction(atWindowPoint: NSPoint(x: 200, y: 28)) {
                copyAction = true
            } else {
                copyAction = false
            }
            return (
                row.hitTest(NSPoint(x: 574, y: 28)) === row,
                row.hitTest(NSPoint(x: 200, y: 28)) === row,
                deleteAction,
                copyAction
            )
        }
        try expect(
            historyRowHitTargets.delete,
            equals: true,
            "history rows should own delete-zone clicks"
        )
        try expect(
            historyRowHitTargets.row,
            equals: true,
            "history rows should keep transcript clicks on the copy action"
        )
        try expect(
            historyRowHitTargets.deleteAction,
            equals: true,
            "history delete zones should resolve to deletion"
        )
        try expect(
            historyRowHitTargets.copyAction,
            equals: true,
            "history transcript bodies should resolve to clipboard copy"
        )
        try expect(
            transcriptionDurationLabel(0.1234),
            equals: "0.123 s",
            "history timing should be displayed in seconds with millisecond precision"
        )
        try expect(
            transcriptionDurationLabel(nil),
            equals: "\u{2014}",
            "legacy history entries should not invent transcription timing"
        )

        let timing = ASRTimingBreakdown(
            totalSeconds: 0.295,
            workerQueueSeconds: 0.001,
            decoderPreparationSeconds: 0.002,
            fluidCallSeconds: 0.290,
            fluidProcessingSeconds: 0.286
        )
        let entriesWithBreakdown = [
            TranscriptHistoryEntry(
                text: "timed",
                transcriptionDurationSeconds: timing.totalSeconds,
                asrTiming: timing
            )
        ]
        let encodedEntries = try JSONEncoder().encode(entriesWithBreakdown)
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: encodedEntries),
            equals: entriesWithBreakdown,
            "history timing metadata should survive persistence"
        )
        try expect(
            asrTimingTooltip(timing)?.contains("FluidAudio  286.0 ms"),
            equals: true,
            "history timing tooltip should expose FluidAudio's own processing time"
        )

        let legacyEntryData = Data(
            #"[{"text":"legacy","transcriptionDurationSeconds":0.25}]"#.utf8
        )
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: legacyEntryData),
            equals: [TranscriptHistoryEntry(text: "legacy", transcriptionDurationSeconds: 0.25)],
            "history entries saved before detailed metrics should remain decodable"
        )

        let metricLine = DictationLatencyMetrics(
            audioSeconds: 2,
            hotkeyDispatchSeconds: 0.0005,
            releasePreparationSeconds: 0.001,
            settingsRefreshSeconds: 0.0002,
            releasePermissionCheckSeconds: 0.0003,
            audioFinalizeSeconds: 0.002,
            audioDetachSeconds: 0.0001,
            journalFlushSeconds: 0.0015,
            audioFlattenSeconds: 0.0004,
            transcribingUISeconds: 0.003,
            taskQueueSeconds: 0.004,
            releaseToASRSeconds: 0.010,
            asrTiming: timing,
            postprocessingSeconds: 0.005,
            historyPersistenceSeconds: 0.006,
            journalCleanupSeconds: 0.007,
            permissionRecheckSeconds: 0.008,
            insertionDispatchSeconds: 0.009,
            releaseToPasteDispatchSeconds: 0.330,
            enterDelaySeconds: nil,
            pasteSucceeded: true
        ).logLine
        try expect(
            metricLine.contains("hotkey_dispatch=0.5 ms")
                && metricLine.contains("journal_flush=1.5 ms")
                && metricLine.contains("fluid_processing=286.0 ms")
                && metricLine.contains("release_to_paste=330.0 ms")
                && metricLine.contains("paste=ok"),
            equals: true,
            "latency log should expose model, end-to-end, and insertion outcomes"
        )
    }

    private static func testDictationUsageStatistics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        let july10 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 10))!
        let july11 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 10))!
        let july17 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 10))!
        let july18 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 10))!

        var stats: [DailyDictationUsage] = []
        stats = addingDictationUsageSample(to: stats,
                                           at: july10,
                                           characterCount: 40,
                                           audioSeconds: 4,
                                           asrSeconds: 0.4,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july11,
                                           characterCount: 100,
                                           audioSeconds: 10,
                                           asrSeconds: 0.5,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july17,
                                           characterCount: 300,
                                           audioSeconds: 30,
                                           asrSeconds: 0.75,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july18,
                                           characterCount: 900,
                                           audioSeconds: 90,
                                           asrSeconds: 1.2,
                                           calendar: calendar)

        let snapshot = lastSevenCompletedDictationUsage(stats,
                                                         referenceDate: reference,
                                                         calendar: calendar)
        try expect(snapshot.days.count, equals: 7,
                   "statistics should always contain seven completed calendar days")
        try expect(snapshot.days.first?.usage.day, equals: "2026-07-11",
                   "statistics should begin seven days before today")
        try expect(snapshot.days.last?.usage.day, equals: "2026-07-17",
                   "statistics should end yesterday")
        try expect(snapshot.totalCharacters, equals: 400,
                   "statistics should exclude both older data and today's dictations")
        try expect(snapshot.totalDictations, equals: 2,
                   "statistics should aggregate completed dictations")
        try expect(snapshot.totalAudioSeconds, equals: 40,
                   "statistics should aggregate recorded audio duration")
        try expect(snapshot.totalASRSeconds, equals: 1.25,
                   "statistics should aggregate ASR duration")

        let log = """
        [23:59:58] 2.00 s audio → 0.20 s → 20 chars
        [00:00:01] HotkeyListener: tap active
        [00:00:02] 3.00 s audio → 0.30 s → 30 chars
        [00:00:03] 1.00 s audio → 0.10 s → 0 chars
        """
        let imported = importedDailyDictationUsage(
            from: log,
            fileCreatedAt: calendar.date(from: DateComponents(year: 2026, month: 7, day: 3))!,
            calendar: calendar
        )
        try expect(imported.count, equals: 2,
                   "log import should infer a new day when timestamps cross midnight")
        try expect(imported.first?.characterCount, equals: 20,
                   "log import should preserve the first day's characters")
        try expect(imported.last?.characterCount, equals: 30,
                   "log import should ignore empty transcripts")
    }

    private static func testAudioLevelMetering() throws {
        var accumulator = AudioSampleAccumulator()
        accumulator.append([])
        accumulator.append([1, 2])
        accumulator.append([3, 4, 5])
        try expect(
            accumulator.sampleCount,
            equals: 5,
            "segmented audio accumulator should track total sample count"
        )
        let captured = accumulator.drain()
        try expect(
            accumulator.sampleCount,
            equals: 0,
            "segmented audio accumulator should reset after drain"
        )
        try expect(
            captured.flattened(),
            equals: [1, 2, 3, 4, 5],
            "segmented audio accumulator should preserve sample order when flattened"
        )

        try expect(
            normalizedAudioLevel(from: Array(repeating: 0, count: 128)),
            equals: 0,
            "silence should map to zero recording level"
        )

        let lowVoice = normalizedAudioLevel(from: Array(repeating: 0.004, count: 128))
        let quiet = normalizedAudioLevel(from: Array(repeating: 0.01, count: 128))
        let normal = normalizedAudioLevel(from: Array(repeating: 0.12, count: 128))
        let loud = normalizedAudioLevel(from: Array(repeating: 4.0, count: 128))

        guard lowVoice > 0 else {
            throw SelfTestFailure.failed("low close-mic voice should rise above the visual gate")
        }
        guard quiet > 0 else {
            throw SelfTestFailure.failed("quiet speech-like input should rise above zero")
        }
        guard normal > quiet else {
            throw SelfTestFailure.failed("higher RMS should produce a higher visual level")
        }
        try expect(
            loud,
            equals: 1,
            "out-of-range samples should clamp to maximum visual level"
        )

        try expect(
            normalizedAudioLevel(from: [.nan, .infinity, -.infinity]),
            equals: 0,
            "non-finite samples should not produce a visible level"
        )
        try expect(
            visibleRecordingLevel(rawLevel: .nan),
            equals: 0,
            "visible recording level should ignore non-finite input"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 0.8),
            equals: 0.8,
            "visible recording level should pass through normal input immediately"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 1.2),
            equals: 1,
            "visible recording level should clamp high input"
        )

        let idlePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0)
        let voicePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0.8)
        guard voicePhaseSpeed > idlePhaseSpeed else {
            throw SelfTestFailure.failed("voice should visibly accelerate the recording waveform")
        }
        try expect(
            recordingHUDPhaseSpeed(mode: .transcribing, level: 1),
            equals: RECORDING_HUD_TRANSCRIBING_PHASE_SPEED,
            "transcribing animation speed should not depend on stale microphone level"
        )
    }

    private static func testAudioConversion() throws {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 2,
                                               interleaved: false),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000,
                                             channels: 1,
                                             interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false),
              let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 480),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 480),
              let stereoChannels = stereo.floatChannelData,
              let monoChannel = mono.floatChannelData?[0] else {
            throw SelfTestFailure.failed("could not create audio conversion test buffers")
        }
        stereo.frameLength = 480
        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = 0.02
        }

        let rms = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: rms),
            equals: [0],
            "manual mono mix should select the active close-mic channel when another channel is near-silent"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: 480,
                     to: monoChannel)
        mono.frameLength = 480
        try expect(
            monoChannel[0],
            equals: 0.5,
            "manual mono mix should preserve the selected active channel"
        )

        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = -0.5
        }
        let balancedRMS = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: balancedRMS),
            equals: [0, 1],
            "manual mono mix should average multiple similarly active channels"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: balancedRMS),
                     frameCount: 480,
                     to: monoChannel)
        try expect(
            monoChannel[0],
            equals: 0,
            "manual mono mix should average selected channels with equal weight"
        )

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 320),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw SelfTestFailure.failed("could not create audio converter")
        }
        var error: NSError?
        let inputProvider = AudioConverterInputProvider(buffer: mono)
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            throw SelfTestFailure.failed("audio conversion failed: \(error?.localizedDescription ?? "?")")
        }
        guard converted.format.channelCount == 1,
              Int(converted.format.sampleRate) == 16_000,
              converted.frameLength > 0 else {
            throw SelfTestFailure.failed("audio conversion should produce 16 kHz mono samples")
        }
    }

    private static func testTranscriptCorrections() throws {
        try expect(
            correctionSourcePrefill(from: "  first line\n\nsecond\tline  "),
            equals: "first line second line",
            "correction source prefill should collapse transcript whitespace"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "a", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 4)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should stay inside correction source byte limits"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "é", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should clip at character boundaries"
        )

        let normalized = normalizedTranscriptCorrections([
            TranscriptCorrection(source: "  Yeti   Nano  ", replacement: "  Blue mic  "),
            TranscriptCorrection(source: "yeti nano", replacement: "USB mic"),
            TranscriptCorrection(source: "", replacement: "ignored"),
            TranscriptCorrection(source: "empty replacement", replacement: "   ")
        ])
        try expect(
            normalized,
            equals: [TranscriptCorrection(source: "yeti nano", replacement: "USB mic")],
            "normalization should trim, drop incomplete entries, collapse duplicate sources, and keep the latest replacement"
        )

        let boundedCorrections = normalizedTranscriptCorrections(
            [
                TranscriptCorrection(source: String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 1),
                                     replacement: "replacement"),
                TranscriptCorrection(source: "source",
                                     replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES + 1)),
                TranscriptCorrection(source: "nul\u{0}source", replacement: "replacement"),
                TranscriptCorrection(source: "valid", replacement: "replacement")
            ]
            + (0..<(MAX_TRANSCRIPT_CORRECTIONS + 3)).map {
                TranscriptCorrection(source: "source-\($0)", replacement: "replacement-\($0)")
            }
            + [
                TranscriptCorrection(source: "source-0", replacement: "updated")
            ]
        )
        try expect(
            boundedCorrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalization should cap stored correction count"
        )
        try expect(
            boundedCorrections.first,
            equals: TranscriptCorrection(source: "valid", replacement: "replacement"),
            "normalization should keep valid corrections while dropping oversized and NUL-containing entries"
        )
        try expect(
            boundedCorrections.dropFirst().first,
            equals: TranscriptCorrection(source: "source-0", replacement: "updated"),
            "normalization should still let later duplicates update retained corrections"
        )
        try expect(
            boundedCorrections.contains(where: { $0.source == "source-\(MAX_TRANSCRIPT_CORRECTIONS)" }),
            equals: false,
            "normalization should drop new unique corrections after the cap"
        )

        let applied = TranscriptCorrector.apply(
            to: "parakeet tdt and parakeetish and PARakeet",
            corrections: [
                TranscriptCorrection(source: "parakeet", replacement: "Parakey"),
                TranscriptCorrection(source: "parakeet tdt", replacement: "Parakeet TDT")
            ]
        )
        try expect(
            applied.text,
            equals: "Parakeet TDT and parakeetish and Parakey",
            "corrections should prefer longer phrases and respect word boundaries"
        )
        try expect(
            applied.appliedCount,
            equals: 2,
            "correction count should track applied non-overlapping replacements"
        )

        let transferred = try TranscriptCorrectionsTransfer.decode(
            TranscriptCorrectionsTransfer.encode([
                TranscriptCorrection(source: "  Right Option  ", replacement: "R-Option")
            ])
        )
        try expect(
            transferred,
            equals: [TranscriptCorrection(source: "Right Option", replacement: "R-Option")],
            "document transfer should round-trip normalized corrections"
        )

        let legacyData = try JSONEncoder().encode([
            TranscriptCorrection(source: "  old phrase  ", replacement: "new phrase")
        ])
        try expect(
            try TranscriptCorrectionsTransfer.decode(legacyData),
            equals: [TranscriptCorrection(source: "old phrase", replacement: "new phrase")],
            "legacy bare-array correction files should remain importable"
        )

        var oversizedDecodeRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.decode(
                Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedDecodeRejected = true
            }
        }
        try expect(oversizedDecodeRejected, equals: true,
                   "correction transfer should reject oversized in-memory data before decoding")

        let transferTmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let transferFileManager = FileManager.default
        let oversized = transferTmpDir
            .appendingPathComponent("parakey-corrections-oversized-\(UUID().uuidString).json")
        try Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            .write(to: oversized)
        defer { try? transferFileManager.removeItem(at: oversized) }
        var oversizedRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: oversized)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedRejected = true
            }
        }
        try expect(oversizedRejected, equals: true,
                   "correction transfer should reject oversized files before decoding")

        let nonFile = transferTmpDir
            .appendingPathComponent("parakey-corrections-directory-\(UUID().uuidString)")
        try transferFileManager.createDirectory(at: nonFile, withIntermediateDirectories: false)
        defer { try? transferFileManager.removeItem(at: nonFile) }
        var nonFileRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: nonFile)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                nonFileRejected = true
            }
        }
        try expect(nonFileRejected, equals: true,
                   "correction transfer should reject non-file paths")

        let readTarget = transferTmpDir
            .appendingPathComponent("parakey-corrections-read-target-\(UUID().uuidString).json")
        try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "source", replacement: "replacement")],
            to: readTarget
        )
        defer { try? transferFileManager.removeItem(at: readTarget) }
        let readLink = transferTmpDir
            .appendingPathComponent("parakey-corrections-read-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: readLink, withDestinationURL: readTarget)
        defer { try? transferFileManager.removeItem(at: readLink) }
        var symlinkReadRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: readLink)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkReadRejected = true
            }
        }
        try expect(symlinkReadRejected, equals: true,
                   "correction transfer should reject reads through leaf symlinks")

        let writeTarget = transferTmpDir
            .appendingPathComponent("parakey-corrections-write-target-\(UUID().uuidString).json")
        try Data("target\n".utf8).write(to: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeTarget) }
        let writeLink = transferTmpDir
            .appendingPathComponent("parakey-corrections-write-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: writeLink, withDestinationURL: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeLink) }
        var symlinkWriteRejected = false
        do {
            try TranscriptCorrectionsTransfer.write(
                [TranscriptCorrection(source: "source", replacement: "replacement")],
                to: writeLink
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkWriteRejected = true
            }
        }
        try expect(symlinkWriteRejected, equals: true,
                   "correction transfer should reject writes through leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: writeTarget), encoding: .utf8),
            equals: "target\n",
            "correction transfer symlink rejection should leave the target untouched"
        )

        let remoteOnlyChange = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            local: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            remote: [TranscriptCorrection(source: "old phrase", replacement: "remote")]
        )
        try expect(
            remoteOnlyChange,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [TranscriptCorrection(source: "old phrase", replacement: "remote")],
                conflictingSources: []
            ),
            "sync merge should accept remote changes when local has not changed"
        )

        let nonConflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old")
            ],
            local: [TranscriptCorrection(source: "shared", replacement: "local")],
            remote: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old"),
                TranscriptCorrection(source: "remote only", replacement: "remote")
            ]
        )
        try expect(
            nonConflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [
                    TranscriptCorrection(source: "shared", replacement: "local"),
                    TranscriptCorrection(source: "remote only", replacement: "remote")
                ],
                conflictingSources: []
            ),
            "sync merge should combine non-conflicting local edits, local deletes, and remote additions"
        )

        let conflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "same source", replacement: "old")],
            local: [TranscriptCorrection(source: "same source", replacement: "local")],
            remote: [TranscriptCorrection(source: "same source", replacement: "remote")]
        )
        try expect(
            conflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(corrections: [],
                                                        conflictingSources: ["same source"]),
            "sync merge should report same-source edits that changed differently on both sides"
        )

        let normalizedSyncPath = normalizedCorrectionSyncFilePath(" /tmp/superdictate/../SuperDictate Corrections.superdictate-corrections\n")
        try expect(
            normalizedSyncPath,
            equals: "/tmp/SuperDictate Corrections.superdictate-corrections",
            "correction sync path normalization should trim and standardize absolute paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("relative/path.superdictate-corrections"),
            equals: nil,
            "correction sync path normalization should reject relative paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/tmp/\u{0}superdictate.superdictate-corrections"),
            equals: nil,
            "correction sync path normalization should reject NUL bytes"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/" + String(repeating: "x", count: MAX_CORRECTION_SYNC_PATH_BYTES)),
            equals: nil,
            "correction sync path normalization should reject oversized paths"
        )

        // Reject leaf-symlinks at the sync path so an attacker who can
        // plant a symlink at the persisted sync-file location cannot use
        // the periodic auto-write to overwrite an unrelated file.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fm = FileManager.default
        let nonexistent = tmpDir.appendingPathComponent("parakey-sync-test-missing-\(UUID().uuidString).json")
        try validateCorrectionSyncPath(nonexistent) // missing files are allowed (first-time write)

        let regular = tmpDir.appendingPathComponent("parakey-sync-test-regular-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: regular)
        defer { try? fm.removeItem(at: regular) }
        try validateCorrectionSyncPath(regular)

        let target = tmpDir.appendingPathComponent("parakey-sync-test-target-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: target)
        defer { try? fm.removeItem(at: target) }
        let link = tmpDir.appendingPathComponent("parakey-sync-test-link-\(UUID().uuidString).json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? fm.removeItem(at: link) }
        var rejected = false
        do {
            try validateCorrectionSyncPath(link)
        } catch is TranscriptCorrectionsSyncPathError {
            rejected = true
        }
        try expect(rejected, equals: true,
                   "validateCorrectionSyncPath should reject a leaf symlink")
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: TranscriptCorrectionsSyncPathError.isSymbolicLink),
            equals: true,
            "unsafe sync paths should stop configured correction sync"
        )
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: NSError(domain: "ParakeyTest", code: 1)),
            equals: false,
            "unrelated sync errors should not clear the configured correction sync path"
        )
        try expect(
            correctionSyncFingerprint(for: link),
            equals: nil,
            "correction sync fingerprinting should not follow leaf symlinks"
        )

        let sameSizeA = tmpDir.appendingPathComponent("parakey-sync-fingerprint-a-\(UUID().uuidString).json")
        let sameSizeB = tmpDir.appendingPathComponent("parakey-sync-fingerprint-b-\(UUID().uuidString).json")
        try Data("aaaa".utf8).write(to: sameSizeA)
        try Data("bbbb".utf8).write(to: sameSizeB)
        defer {
            try? fm.removeItem(at: sameSizeA)
            try? fm.removeItem(at: sameSizeB)
        }
        let sharedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeA.path)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeB.path)

        guard let fingerprintA = correctionSyncFingerprint(for: sameSizeA),
              let fingerprintB = correctionSyncFingerprint(for: sameSizeB) else {
            throw SelfTestFailure.failed("correction sync fingerprint should read regular files")
        }
        try expect(
            fingerprintA.size,
            equals: fingerprintB.size,
            "same-size sync files should have equal size metadata in the fingerprint"
        )
        try expect(
            fingerprintA == fingerprintB,
            equals: false,
            "correction sync fingerprint should detect content changes even when file size matches"
        )

        // The full legal correction set must encode within the
        // transfer cap: 512 entries at the per-field caps is ~2.4 MB
        // encoded, which silently failed to save under the old 2 MiB
        // cap. Also pin that it really is over 2 MiB, documenting why
        // the cap moved to 4 MiB.
        let worstCaseSet = (0..<MAX_TRANSCRIPT_CORRECTIONS).map { index in
            TranscriptCorrection(
                source: String(format: "%06d-", index)
                    + String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES - 7),
                replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES)
            )
        }
        let worstCaseData = try TranscriptCorrectionsTransfer.encode(worstCaseSet)
        try expect(
            worstCaseData.count > 2 * 1024 * 1024,
            equals: true,
            "worst-case legal correction set should exceed the old 2 MiB cap (why the cap is now larger)"
        )
        try expect(
            worstCaseData.count <= TranscriptCorrectionsTransfer.maxFileBytes,
            equals: true,
            "worst-case legal correction set must fit the transfer cap with JSON-overhead headroom"
        )
        try expect(
            try TranscriptCorrectionsTransfer.decode(worstCaseData).count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "worst-case legal correction set should round-trip through the transfer cap"
        )

        // Near the correction cap a merge can briefly exceed it. The
        // sync baseline must store the same normalized (capped) list
        // that is written to the file — a raw over-cap baseline makes
        // the capped-out entry look like a local deletion later.
        let sharedNearCap = (0..<(MAX_TRANSCRIPT_CORRECTIONS - 1)).map {
            TranscriptCorrection(source: "shared-\($0)", replacement: "same")
        }
        let nearCapMerge = mergedTranscriptCorrectionsForSync(
            base: sharedNearCap,
            local: sharedNearCap + [TranscriptCorrection(source: "local-extra", replacement: "local")],
            remote: sharedNearCap + [TranscriptCorrection(source: "remote-extra", replacement: "remote")]
        )
        try expect(
            nearCapMerge.conflictingSources,
            equals: [],
            "near-cap merge with disjoint additions should not conflict"
        )
        try expect(
            nearCapMerge.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 1,
            "near-cap merge result can exceed the cap before normalization"
        )
        let nearCapNormalized = normalizedTranscriptCorrections(nearCapMerge.corrections)
        try expect(
            nearCapNormalized.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalizing the near-cap merge result should drop the over-cap entry"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "local-extra", replacement: "local")),
            equals: true,
            "normalization keeps the earlier (local) addition at the cap"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "remote-extra", replacement: "remote")),
            equals: false,
            "the capped-out remote addition is exactly what the baseline must also drop"
        )

        // Fingerprinting the bytes we wrote must agree with a fresh
        // disk fingerprint when nobody touched the file in between —
        // the sync path uses the in-memory form so a provider replacing
        // the file in the write-to-fingerprint window is still detected
        // by the next scan.
        let fingerprintWriteTarget = tmpDir
            .appendingPathComponent("parakey-sync-written-fingerprint-\(UUID().uuidString).json")
        let fingerprintWrittenData = try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "fingerprint", replacement: "match")],
            to: fingerprintWriteTarget
        )
        defer { try? fm.removeItem(at: fingerprintWriteTarget) }
        guard let fingerprintFromDisk = correctionSyncFingerprint(for: fingerprintWriteTarget) else {
            throw SelfTestFailure.failed("disk fingerprint should be readable right after a write")
        }
        try expect(
            correctionSyncFingerprint(forWrittenData: fingerprintWrittenData, at: fingerprintWriteTarget),
            equals: fingerprintFromDisk,
            "fingerprint of written bytes should match the disk fingerprint of an untouched file"
        )

        // Counted decode keeps the file's pre-normalization entry count
        // so the import dialog can disclose truncation.
        let countedOriginal = (0..<(MAX_TRANSCRIPT_CORRECTIONS + 5)).map {
            TranscriptCorrection(source: "counted-\($0)", replacement: "kept")
        }
        let countedEncoder = JSONEncoder()
        countedEncoder.dateEncodingStrategy = .iso8601
        let countedDocument = TranscriptCorrectionsDocument(
            schemaVersion: TranscriptCorrectionsTransfer.schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: countedOriginal
        )
        let counted = try TranscriptCorrectionsTransfer.decodeCounted(countedEncoder.encode(countedDocument))
        try expect(
            counted.originalCount,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 5,
            "counted decode should report the file's pre-normalization entry count"
        )
        try expect(
            counted.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "counted decode should still normalize down to the correction cap"
        )
        let countedLegacy = try TranscriptCorrectionsTransfer.decodeCounted(
            try JSONEncoder().encode([TranscriptCorrection(source: "  legacy  ", replacement: "entry")])
        )
        try expect(
            countedLegacy,
            equals: TranscriptCorrectionsTransfer.CountedDecodeResult(
                corrections: [TranscriptCorrection(source: "legacy", replacement: "entry")],
                originalCount: 1
            ),
            "counted decode should support legacy bare-array files"
        )

        // Import dialog copy: state the original count when entries
        // will be dropped, and warn before a cap-overflowing merge.
        try expect(
            correctionImportCountText(sourceName: "file.superdictate-corrections",
                                      originalCount: 3,
                                      keptCount: 3),
            equals: "file.superdictate-corrections contains 3 corrections.",
            "import count text should stay simple when nothing is dropped"
        )
        let truncatedImportText = correctionImportCountText(
            sourceName: "big.superdictate-corrections",
            originalCount: MAX_TRANSCRIPT_CORRECTIONS + 88,
            keptCount: MAX_TRANSCRIPT_CORRECTIONS
        )
        try expect(
            truncatedImportText.contains("contains \(MAX_TRANSCRIPT_CORRECTIONS + 88) entries"),
            equals: true,
            "import count text should state the file's original entry count when entries are dropped"
        )
        try expect(
            truncatedImportText.contains("first \(MAX_TRANSCRIPT_CORRECTIONS)"),
            equals: true,
            "import count text should state how many corrections will actually be kept"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: 10, newCount: 10),
            equals: nil,
            "merge cap warning should stay silent when the merged set fits"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: MAX_TRANSCRIPT_CORRECTIONS,
                                                newCount: 8)?.contains("8 would be dropped"),
            equals: true,
            "merge cap warning should state how many corrections a merge would drop"
        )
    }

    private static func testFillerWordRemoval() throws {
        // Mid-sentence filler with surrounding commas → orphan comma
        // gets collapsed.
        let mid = FillerWordRemover.apply(to: "So, um, I was going.")
        try expect(mid.text, equals: "So, I was going.", "mid-sentence filler should leave a single comma")
        try expect(mid.removedCount, equals: 1, "mid-sentence filler removal count")

        // Sentence-initial filler with leading-comma cleanup AND
        // capitalisation restored (the original 'U' was uppercase).
        let initial = FillerWordRemover.apply(to: "Um, hello.")
        try expect(initial.text, equals: "Hello.", "sentence-initial filler should re-capitalise the next word")
        try expect(initial.removedCount, equals: 1, "sentence-initial filler removal count")

        let secondSentence = FillerWordRemover.apply(to: "This is the first sentence. Um this is the second sentence.")
        try expect(
            secondSentence.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should re-capitalise the next word"
        )
        try expect(secondSentence.removedCount, equals: 1, "second-sentence filler removal count")

        let secondSentenceWithComma = FillerWordRemover.apply(to: "This is the first sentence. Um, this is the second sentence.")
        try expect(
            secondSentenceWithComma.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should not leave an orphan comma"
        )
        try expect(secondSentenceWithComma.removedCount, equals: 1, "second-sentence comma filler removal count")

        let secondSentenceQuestion = FillerWordRemover.apply(to: "This is the first sentence. Um? this is the second sentence.")
        try expect(
            secondSentenceQuestion.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler with its own punctuation should take that punctuation with it"
        )
        try expect(secondSentenceQuestion.removedCount, equals: 1, "second-sentence question filler removal count")

        let capitalizedMidSentence = FillerWordRemover.apply(to: "This is not a sentence boundary Um this stays lowercase.")
        try expect(
            capitalizedMidSentence.text,
            equals: "This is not a sentence boundary this stays lowercase.",
            "capitalized fillers away from sentence starts should not force capitalization"
        )
        try expect(capitalizedMidSentence.removedCount, equals: 1, "capitalized mid-sentence filler removal count")

        // Bare filler with adjacent punctuation collapses to empty.
        let bare = FillerWordRemover.apply(to: "Um.")
        try expect(bare.text, equals: "", "bare filler with trailing punctuation should leave empty string")
        try expect(bare.removedCount, equals: 1, "bare filler removal count")

        // Filler with no surrounding punctuation just leaves a space
        // that gets collapsed away.
        let inline = FillerWordRemover.apply(to: "I'm uh going to the store.")
        try expect(inline.text, equals: "I'm going to the store.", "inline filler should collapse the leftover whitespace")
        try expect(inline.removedCount, equals: 1, "inline filler removal count")

        // Compound interjection "uh-huh" must NOT match — the hyphen is
        // part of the boundary class.
        let uhHuh = FillerWordRemover.apply(to: "Yeah, uh-huh.")
        try expect(uhHuh.text, equals: "Yeah, uh-huh.", "uh-huh must not be stripped")
        try expect(uhHuh.removedCount, equals: 0, "uh-huh removal count")

        // Words that *contain* a filler substring must not match. "her"
        // contains "er", "sum" contains "um", "exercise" contains "er".
        let contains = FillerWordRemover.apply(to: "Her sum exercise is harder.")
        try expect(contains.text, equals: "Her sum exercise is harder.", "filler substrings inside larger words must be preserved")
        try expect(contains.removedCount, equals: 0, "no removals when fillers are embedded in real words")

        // Multiple fillers in one utterance all get stripped.
        let multi = FillerWordRemover.apply(to: "Um, ah, I uh think so.")
        try expect(multi.text, equals: "I think so.", "multiple fillers should all be removed and artifacts cleaned up")
        try expect(multi.removedCount, equals: 3, "multi-filler removal count")

        // Empty input should be a no-op.
        let empty = FillerWordRemover.apply(to: "")
        try expect(empty.text, equals: "", "empty input passes through unchanged")
        try expect(empty.removedCount, equals: 0, "empty input has zero removals")

        // No fillers present → identical text, zero removals.
        let clean = FillerWordRemover.apply(to: "Hello world.")
        try expect(clean.text, equals: "Hello world.", "filler-free input passes through unchanged")
        try expect(clean.removedCount, equals: 0, "filler-free input has zero removals")

        // Elongated fillers — common in real dictation. The word-
        // boundary lookahead would have rejected these without the
        // per-pattern trailing-repeat allowance.
        let elongatedUm = FillerWordRemover.apply(to: "Ummm, hello.")
        try expect(elongatedUm.text, equals: "Hello.", "ummm should be stripped like um")
        try expect(elongatedUm.removedCount, equals: 1, "elongated um removal count")

        let elongatedUh = FillerWordRemover.apply(to: "Uhhh I think so.")
        try expect(elongatedUh.text, equals: "I think so.", "uhhh should be stripped like uh")
        try expect(elongatedUh.removedCount, equals: 1, "elongated uh removal count")

        let elongatedAh = FillerWordRemover.apply(to: "Ahhh, that makes sense.")
        try expect(elongatedAh.text, equals: "That makes sense.", "ahhh should be stripped like ah")
        try expect(elongatedAh.removedCount, equals: 1, "elongated ah removal count")

        // `hm+` covers both "hm" (single m) and "hmmm" (extended). The
        // earlier fixed-list "hmm" entry rejected the single-m form.
        let shortHm = FillerWordRemover.apply(to: "Hm, interesting.")
        try expect(shortHm.text, equals: "Interesting.", "short hm should be stripped like hmm")
        try expect(shortHm.removedCount, equals: 1, "short hm removal count")

        // Words containing the new repeat-friendly patterns must still
        // pass through. "ohm" embeds "hm" but has a leading letter.
        let embedded = FillerWordRemover.apply(to: "An ohm is a unit.")
        try expect(embedded.text, equals: "An ohm is a unit.", "ohm must not match hm")
        try expect(embedded.removedCount, equals: 0, "ohm should produce zero removals")

        // Two consecutive fillers used to leave ",," because the
        // comma-collapse pass was single-pass/non-overlapping: it
        // consumed one ", ," pair and the whitespace-before-punctuation
        // pass then glued the leftover " ," into ",,".
        let consecutive = FillerWordRemover.apply(to: "So, um, uh, yes.")
        try expect(consecutive.text, equals: "So, yes.", "consecutive fillers should collapse to a single comma")
        try expect(consecutive.removedCount, equals: 2, "consecutive filler removal count")

        // Three consecutive fillers exercise runs longer than one
        // collapse step.
        let tripleRun = FillerWordRemover.apply(to: "He said, um, uh, er, no.")
        try expect(tripleRun.text, equals: "He said, no.", "a run of three fillers should collapse to a single comma")
        try expect(tripleRun.removedCount, equals: 3, "triple filler removal count")

        // Consecutive fillers mid-sentence keep exactly one comma,
        // matching the single-filler behavior above.
        let midRun = FillerWordRemover.apply(to: "I think, um, uh, we should go.")
        try expect(midRun.text, equals: "I think, we should go.", "mid-sentence consecutive fillers should keep one comma")
        try expect(midRun.removedCount, equals: 2, "mid-sentence consecutive filler removal count")

        // Trailing filler before terminal punctuation used to leave
        // ",." because no pass cleaned a comma glued onto a period.
        let trailing = FillerWordRemover.apply(to: "That's all, um.")
        try expect(trailing.text, equals: "That's all.", "trailing filler should not leave a comma before the period")
        try expect(trailing.removedCount, equals: 1, "trailing filler removal count")

        let beforeQuestion = FillerWordRemover.apply(to: "Is that right, um?")
        try expect(beforeQuestion.text, equals: "Is that right?", "filler before a question mark should not leave a comma")
        try expect(beforeQuestion.removedCount, equals: 1, "filler before question mark removal count")

        let beforeBang = FillerWordRemover.apply(to: "Stop, um!")
        try expect(beforeBang.text, equals: "Stop!", "filler before an exclamation mark should not leave a comma")
        try expect(beforeBang.removedCount, equals: 1, "filler before exclamation mark removal count")

        // Sentence-initial filler with its own terminal punctuation:
        // the leading-strip class must include "?" and "!" or the
        // orphaned punctuation survives ("Um? What?" → "? What?").
        let leadingQuestion = FillerWordRemover.apply(to: "Um? What?")
        try expect(leadingQuestion.text, equals: "What?", "leading filler question should take its punctuation with it")
        try expect(leadingQuestion.removedCount, equals: 1, "leading filler question removal count")

        let leadingBang = FillerWordRemover.apply(to: "Ah! Careful.")
        try expect(leadingBang.text, equals: "Careful.", "leading filler exclamation should take its punctuation with it")
        try expect(leadingBang.removedCount, equals: 1, "leading filler exclamation removal count")
    }

    private static func testAudioInputDeviceFiltering() throws {
        let pseudo = AudioInputDevice(id: 1,
                                      uid: "CADefaultDeviceAggregate-42159-0",
                                      name: "CADefaultDeviceAggregate-42159-0")
        let real = AudioInputDevice(id: 2,
                                    uid: "real-yeti-nano",
                                    name: "Yeti Nano")

        try expect(
            isDefaultAggregateAudioInputDevice(pseudo),
            equals: true,
            "CoreAudio default aggregate devices should be recognized"
        )
        try expect(
            isDefaultAggregateAudioInputDevice(real),
            equals: false,
            "named microphones should remain selectable"
        )
        try expect(
            normalizedInputDevicePreference(" Yeti Nano\n"),
            equals: "Yeti Nano",
            "input device preferences should be trimmed before storing"
        )
        try expect(
            normalizedInputDevicePreference(pseudo.uid),
            equals: nil,
            "input device preferences should reject CoreAudio default aggregates"
        )
        try expect(
            normalizedInputDevicePreference("real\u{0}device"),
            equals: nil,
            "input device preferences should reject NUL bytes"
        )
        try expect(
            normalizedInputDevicePreference(String(repeating: "x", count: MAX_INPUT_DEVICE_PREFERENCE_BYTES + 1)),
            equals: nil,
            "input device preferences should reject oversized values"
        )
        try expect(
            audioInputDevice(matching: pseudo.uid, in: [pseudo, real])?.uid,
            equals: nil,
            "CoreAudio default aggregate preferences should fall back to system default"
        )
        try expect(
            audioInputDevice(matching: " real-yeti-nano\n", in: [real])?.uid,
            equals: "real-yeti-nano",
            "input device preferences should resolve after trimming"
        )
        try expect(
            audioInputDevice(matching: "Yeti Nano", in: [real])?.uid,
            equals: "real-yeti-nano",
            "named microphone preferences should still resolve by display name"
        )
    }

    private static func testSpeechModelStartupStatus() throws {
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0,
                                                phase: .listing)),
            equals: "Checking speech model files…",
            "listing phase should be visible during first-launch model setup"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.25,
                                                phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: "Downloading speech model… 50% (2/4)",
            "download phase should show quantized progress"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.5,
                                                phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: "Loading cached speech model…",
            "cached model load should not pretend to download files"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 1,
                                                phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: "Preparing speech model…",
            "compile phase should be visible without exposing model internals"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0,
                                                  phase: .listing)),
            equals: nil,
            "listing phase should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0.25,
                                                  phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: 0.5,
            "download phase should expose normalized model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0.5,
                                                  phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: nil,
            "cached model load should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 1,
                                                  phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: nil,
            "compile phase should show indeterminate model progress"
        )
        let requiredBytes = speechModelDownloadRequiredBytes(for: .multilingualV3,
                                                             headroomBytes: 100)
        try expect(
            requiredBytes,
            equals: 700 * 1024 * 1024 + 100,
            "speech model download requirement should include model estimate plus headroom"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualV3,
                                              availableBytes: requiredBytes - 1,
                                              requiredBytes: requiredBytes)?.contains("Free some disk space"),
            equals: true,
            "low disk-space failures should explain how to recover"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualV3,
                                              availableBytes: requiredBytes,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "disk-space check should pass once required space is available"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualV3,
                                              availableBytes: nil,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "unknown disk-space readings should not block model startup"
        )
    }

    private static func testModelIntegrity() throws {
        try testSpeechModelCachePathSafety()

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-model-integrity-\(UUID().uuidString)",
                                    isDirectory: true)
        let modelDir = root.appendingPathComponent("Toy.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let modelFile = modelDir.appendingPathComponent("model.mil")
        try Data("hello".utf8).write(to: modelFile)
        let expected = [
            ModelFileDigest(
                relativePath: "Toy.mlmodelc/model.mil",
                sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        ]
        try ModelIntegrity.verifyFiles(root: root,
                                       expectedFiles: expected,
                                       strictDirectories: ["Toy.mlmodelc"])

        var rejectedMismatch = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: String(repeating: "0", count: 64))
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedMismatch = true
        }
        try expect(rejectedMismatch, equals: true,
                   "model integrity should reject digest mismatches")

        try Data("extra".utf8).write(to: modelDir.appendingPathComponent("extra.bin"))
        var rejectedUnexpectedFile = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedFile = true
        }
        try expect(rejectedUnexpectedFile, equals: true,
                   "model integrity should reject unpinned files in strict model bundles")

        try fm.removeItem(at: modelDir.appendingPathComponent("extra.bin"))
        try fm.createDirectory(at: modelDir.appendingPathComponent("empty-extra", isDirectory: true),
                               withIntermediateDirectories: true)
        var rejectedUnexpectedDirectory = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedDirectory = true
        }
        try expect(rejectedUnexpectedDirectory, equals: true,
                   "model integrity should reject unpinned directories in strict model bundles")

        var rejectedBadDigest = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: "not-a-sha256")
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedBadDigest = true
        }
        try expect(rejectedBadDigest, equals: true,
                   "model integrity should reject malformed manifest digests")

        var rejectedDotSegment = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(
                        relativePath: "Toy.mlmodelc/./model.mil",
                        sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                    )
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedDotSegment = true
        }
        try expect(rejectedDotSegment, equals: true,
                   "model integrity should reject dot path segments")

        let symlinkedModelFile = modelDir.appendingPathComponent("model-link.mil")
        try fm.createSymbolicLink(at: symlinkedModelFile, withDestinationURL: modelFile)
        var rejectedSymlinkHashRead = false
        do {
            _ = try ModelIntegrity.sha256Hex(of: symlinkedModelFile,
                                             relativePath: "Toy.mlmodelc/model-link.mil")
        } catch is ModelIntegrityError {
            rejectedSymlinkHashRead = true
        }
        try expect(rejectedSymlinkHashRead, equals: true,
                   "model integrity hashing should not follow leaf symlinks")

        let localParakeetV3Cache = speechModelCacheDirectory(for: .multilingualV3)
        if fm.fileExists(atPath: localParakeetV3Cache.path) {
            try ModelIntegrity.verifyParakeetV3Model(at: localParakeetV3Cache)
        }
    }

    private static func testSpeechModelCachePathSafety() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-cache-safety-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("FluidAudio", isDirectory: true)
        let cache = support.appendingPathComponent("Models/parakeet-v3", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try expect(
            isSafeSpeechModelCacheDirectory(
                cache,
                fluidAudioSupportDirectory: support
            ),
            equals: true,
            "speech model cache reset should allow nested FluidAudio cache paths"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(cache,
                                                             fluidAudioSupportDirectory: support),
            equals: true,
            "speech model cache reset should allow existing plain cache directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(support, fluidAudioSupportDirectory: support),
            equals: false,
            "speech model cache reset should not remove the FluidAudio support root"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.deletingLastPathComponent().appendingPathComponent("FluidAudioBackup/parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject sibling support directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.appendingPathComponent("../Outside/parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject paths that normalize outside FluidAudio support"
        )

        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("parakeet-v3", isDirectory: true)
        try fm.createDirectory(at: outsideCache, withIntermediateDirectories: true)

        let leafLink = support.appendingPathComponent("Models/link-cache", isDirectory: true)
        try fm.createSymbolicLink(at: leafLink, withDestinationURL: outsideCache)
        try expect(
            isSafeSpeechModelCacheDirectory(leafLink, fluidAudioSupportDirectory: support),
            equals: true,
            "speech model cache reset path check should remain string-only"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(leafLink,
                                                             fluidAudioSupportDirectory: support),
            equals: false,
            "speech model cache reset should reject leaf symlink directories before deletion"
        )

        let linkedParent = support.appendingPathComponent("LinkedModels", isDirectory: true)
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(
                linkedParent.appendingPathComponent("parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject symlinked parent directories before deletion"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(speechModelCacheDirectory(for: .multilingualV3)),
            equals: true,
            "FluidAudio v3 cache path should remain inside FluidAudio Application Support"
        )
        let defaultV3Cache = speechModelCacheDirectory(for: .multilingualV3)
        if fm.fileExists(atPath: defaultV3Cache.path) {
            try expect(
                isExistingSpeechModelCacheDirectorySafeForRemoval(defaultV3Cache),
                equals: true,
                "existing FluidAudio v3 cache path should remain removable"
            )
        }
    }

    private static func testUpdate() throws {
        try testUpdateCheckParsing()
        try testUpdateCheckState()
        try testUpdateHelperScript()
        try testUpdateProgressState()
    }

    private static func testUpdateCheckParsing() throws {
        let ok = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                 statusCode: 200,
                                 httpVersion: nil,
                                 headerFields: nil)!
        let notFound = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                       statusCode: 404,
                                       httpVersion: nil,
                                       headerFields: nil)!
        let releaseData = Data(
            #"{"tag_name":"v9.8.7","body":"Notes","html_url":"https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7"}"#.utf8
        )

        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: ok),
            equals: .success(GitHubRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "Notes",
                                           htmlURL: "https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7")),
            "update parsing should decode typed GitHub release payloads"
        )
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: notFound),
            equals: .failure(.httpStatus(404)),
            "update parsing should reject non-2xx HTTP responses with the status code"
        )
        let rateLimited = HTTPURLResponse(url: GITHUB_LATEST_RELEASE_URL,
                                          statusCode: 403,
                                          httpVersion: nil,
                                          headerFields: nil)!
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: rateLimited),
            equals: .failure(.httpStatus(403)),
            "update parsing should surface HTTP 403 distinctly (GitHub rate limiting)"
        )
        let oversizedReleaseData = Data(
            """
            {"tag_name":"v9.8.7","body":"\(String(repeating: "x", count: UpdateCheck.maxReleaseResponseBytes))","html_url":"https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7"}
            """.utf8
        )
        try expect(
            oversizedReleaseData.count > UpdateCheck.maxReleaseResponseBytes,
            equals: true,
            "oversized release response fixture should exceed the parser limit"
        )
        try expect(
            UpdateCheck.parseLatest(data: oversizedReleaseData, response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized release responses before decoding"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":""}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject empty release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":"latest"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-version release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"tag_name":"v01.2.3"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-normal semver tags"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"v999999999999999999999999.2.3"}"#.utf8),
                response: ok
            ),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized numeric version parts"
        )
        try expect(
            parseSemver("999999999999999999999999.2.3"),
            equals: [Int.max, 2, 3],
            "tolerant version parsing should not overflow on oversized components"
        )
        try expect(
            normalizedSkippedUpdateVersions([
                "junk",
                "v1.2.3",
                "1.2.3",
                " V2.0.0\n",
                "01.2.3",
                "3.999999999999999999999999.0"
            ]),
            equals: ["1.2.3", "2.0.0"],
            "skipped update versions should normalize valid versions and discard malformed entries"
        )
        try expect(
            normalizedSkippedUpdateVersions((0..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" }),
            equals: (3..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" },
            "skipped update versions should keep only the most recent bounded entries"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"9.8.7","html_url":"https://example.test/v9.8.7"}"#.utf8),
                response: ok
            ),
            equals: .success(GitHubRelease(tagName: "9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: GITHUB_RELEASES_PAGE.absoluteString)),
            "update parsing should fall back from non-project release URLs"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"tag_name":"v9.8.7","html_url":"https://github.com/shlgd/SuperDictate/releases/tag/v9.8.8"}"#.utf8),
                response: ok
            ),
            equals: .success(GitHubRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: GITHUB_RELEASES_PAGE.absoluteString)),
            "update parsing should fall back when release URL tag does not match the payload tag"
        )
        // Manual-check alert copy: each failure kind gets its own
        // explanation instead of blaming the network for everything.
        try expect(
            manualUpdateCheckFailureText(.network).contains("internet connection"),
            equals: true,
            "network failure text should point at connectivity"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(403)).contains("rate limiting"),
            equals: true,
            "HTTP 403 failure text should mention rate limiting"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(500)).contains("HTTP 500"),
            equals: true,
            "HTTP failure text should include the status code"
        )
        try expect(
            manualUpdateCheckFailureText(.unexpectedResponse).contains("couldn't read"),
            equals: true,
            "unexpected-response failure text should describe an unreadable response"
        )
        try expect(
            UpdateCheck.normalizedReleaseVersion(from: " V1.2.3\n"),
            equals: "1.2.3",
            "release version normalization should allow one leading v"
        )
        try expect(
            normalizedStoredAppVersion(" v2.3.4\n"),
            equals: "2.3.4",
            "stored app version normalization should canonicalize release-style versions"
        )
        try expect(
            normalizedStoredAppVersion("2.3"),
            equals: nil,
            "stored app version normalization should reject incomplete versions"
        )
        try expect(
            normalizedStoredAppVersion("v999999999999999999999999.2.3"),
            equals: nil,
            "stored app version normalization should reject oversized numeric components"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("http://github.com/shlgd/SuperDictate/releases/tag/v9.8.7",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should require HTTPS"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("https://user@github.com/shlgd/SuperDictate/releases/tag/v9.8.7",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should reject userinfo"
        )
        try expect(
            UpdateCheck.sanitizedReleaseURL("https://github.com/shlgd/SuperDictate/releases/tag/v9.8.7?download=1",
                                            expectedTag: "v9.8.7"),
            equals: GITHUB_RELEASES_PAGE.absoluteString,
            "release URL sanitizing should reject query strings"
        )
    }

    private static func testUpdateCheckState() throws {
        let release = GitHubRelease(tagName: "v1.2.4",
                                    version: "1.2.4",
                                    body: "",
                                    htmlURL: GITHUB_RELEASES_PAGE.absoluteString)
        try expect(
            updateCheckResult(for: nil, currentVersion: "1.2.3", skippedVersions: []),
            equals: .failed,
            "nil update checks should be recorded as failed or unavailable"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.4", skippedVersions: []),
            equals: .upToDate,
            "equal release versions should be recorded as up to date"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: []),
            equals: .available,
            "newer releases should be recorded as available"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: ["1.2.4"]),
            equals: .skipped,
            "skipped newer releases should be recorded distinctly"
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: true,
            "active reminders should suppress the matching update version"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.5",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: false,
            "reminders should not suppress newer versions"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(-1),
                                            now: now),
            equals: false,
            "expired reminders should not suppress updates"
        )
        try expect(
            updateCheckDiagnosticText(checkedAt: nil,
                                      source: nil,
                                      result: nil,
                                      releaseVersion: ""),
            equals: "never",
            "missing update-check metadata should render as never"
        )

        // Stale-pause clearing: equal version (expired pause about to
        // be re-shown) and a newer superseding release both clear; an
        // older fetched version or no pause leaves things alone.
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: "1.2.4"),
            equals: true,
            "a fetched release matching the paused version should clear the pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.5", pausedVersion: "1.2.4"),
            equals: true,
            "a newer fetched release should clear a stale pause for the superseded version"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.3", pausedVersion: "1.2.4"),
            equals: false,
            "an older fetched release should keep the existing pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: nil),
            equals: false,
            "no pause means nothing to clear"
        )

        // Persisted pause expiry validation, mirroring the
        // lastUpdateCheck* pattern: corrupt → nil, in-range round-trip,
        // cleared/missing → nil.
        let pauseNow = Date(timeIntervalSince1970: 2_000)
        let validPauseUntil = pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS)
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: validPauseUntil, now: pauseNow),
            equals: validPauseUntil,
            "a stored pause expiry inside the pause window should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: pauseNow.addingTimeInterval(-60), now: pauseNow),
            equals: pauseNow.addingTimeInterval(-60),
            "an already-expired stored pause expiry is legitimate state and should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: "not a date", now: pauseNow),
            equals: nil,
            "a corrupt (non-Date) stored pause expiry should degrade to nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: nil, now: pauseNow),
            equals: nil,
            "a cleared pause expiry should read back as nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(
                storedValue: pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS + 60),
                now: pauseNow
            ),
            equals: nil,
            "an out-of-range future pause expiry should degrade to nil instead of suppressing indefinitely"
        )
        // The paused-version half persists through the same validated
        // app-version normalization tested in testUpdateCheckParsing
        // (normalizedStoredAppVersion: corrupt → nil, round-trip).

        try expect(
            UpdateCheckSource(rawValue: "settings_toggle"),
            equals: .settingsToggle,
            "settings-toggle update checks should round-trip through their persisted raw value"
        )
        try expect(
            UpdateCheckSource.settingsToggle.diagnosticLabel,
            equals: "settings toggle",
            "settings-toggle update checks should label themselves distinctly in diagnostics"
        )
    }

    private static func testUpdateHelperScript() throws {
        try expect(
            shellSingleQuoted("a'b"),
            equals: "'a'\"'\"'b'",
            "shell quoting should preserve embedded single quotes"
        )
        try expect(
            (UPDATE_HELPER_LOG_PATH as NSString).deletingLastPathComponent,
            equals: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs"),
            "update helper log should live in the user's log directory"
        )
        let updateEnv = updateProcessEnvironment(current: [
            "LANG": "C\nbad",
            "USER": "parakey-user",
            "LOGNAME": "parakey-logname",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "BASH_ENV": "/tmp/pwn.sh",
            "ENV": "/tmp/pwn.sh",
            "SHELLOPTS": "xtrace",
            "RUBYOPT": "-r/tmp/pwn.rb",
            "HOMEBREW_BOTTLE_DOMAIN": "https://example.test",
        ])
        try expect(updateEnv["HOME"], equals: Optional(NSHomeDirectory()),
                   "update environment should set HOME explicitly")
        try expect(updateEnv["PATH"],
                   equals: Optional("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
                   "update environment should use a deterministic PATH")
        try expect(updateEnv["LANG"], equals: Optional("en_US.UTF-8"),
                   "update environment should reject unsafe locale values")
        try expect(updateEnv["USER"], equals: Optional("parakey-user"),
                   "update environment should preserve a safe USER value")
        try expect(updateEnv["LOGNAME"], equals: Optional("parakey-logname"),
                   "update environment should preserve a safe LOGNAME value")
        for key in ["BASH_ENV", "ENV", "SHELLOPTS", "RUBYOPT", "HOMEBREW_BOTTLE_DOMAIN"] {
            try expect(updateEnv[key], equals: String?.none,
                       "update environment should not inherit \(key)")
        }
        let systemEnv = systemToolProcessEnvironment(current: [
            "LANG": "en_GB.UTF-8",
            "USER": "parakey-user",
            "BASH_ENV": "/tmp/pwn.sh",
            "DYLD_INSERT_LIBRARIES": "/tmp/pwn.dylib",
            "PATH": "/tmp/bin",
        ])
        try expect(systemEnv["PATH"], equals: Optional("/usr/bin:/bin:/usr/sbin:/sbin"),
                   "system tool environment should not include Homebrew or inherited PATH entries")
        try expect(systemEnv["LANG"], equals: Optional("en_GB.UTF-8"),
                   "system tool environment should preserve a safe locale")
        try expect(systemEnv["USER"], equals: Optional("parakey-user"),
                   "system tool environment should preserve a safe USER value")
        for key in ["BASH_ENV", "DYLD_INSERT_LIBRARIES"] {
            try expect(systemEnv[key], equals: String?.none,
                       "system tool environment should not inherit \(key)")
        }

        let script = updateHelperScript(pid: 123,
                                        brewPath: "/opt/homebrew/bin/brew",
                                        targetVersion: "9.8.7",
                                        statePath: "/tmp/parakey-update.state",
                                        appPath: "/Applications/SuperDictate.app",
                                        releasesPageURL: "https://example.test/releases")
        for fragment in [
            "umask 077",
            "TARGET_VERSION='9.8.7'",
            "STATE_PATH='/tmp/parakey-update.state'",
            "PARAKEY_PID=123",
            "SCRIPT_PATH=\"$0\"",
            "trap cleanup EXIT",
            "/bin/rm -f \"$SCRIPT_PATH\"",
            "printf '[%s] %s\\n' \"$(timestamp)\" \"$*\"",
            "printf '%s\\t%s\\n' \"$phase\" \"$message\" >\"$tmp\"",
            "CASK_TAP='shlgd/superdictate'",
            "CASK_TOKEN='shlgd/superdictate/superdictate'",
            "CASK_INSTALLED_TOKEN='parakey'",
            "PlistBuddy -c \"Print :CFBundleShortVersionString\"",
            "version_at_least \"$installed\" \"$TARGET_VERSION\"",
            "state \"preparing\" \"Preparing Homebrew for Parakey v$TARGET_VERSION...\"",
            "state \"downloading\" \"Downloading Parakey v$TARGET_VERSION...\"",
            "state \"installing\" \"Installing Parakey v$TARGET_VERSION...\"",
            "run_brew tap \"$CASK_TAP\"",
            "run_brew update --force",
            "run_brew fetch --cask --force \"$CASK_TOKEN\"",
            "run_brew upgrade --cask --force --appdir=\"$APP_DIR\" \"$CASK_TOKEN\"",
            "run_brew reinstall --cask --force --appdir=\"$APP_DIR\" \"$CASK_TOKEN\"",
            "installed_target_version",
            "sleep 2",
            "state \"complete\" \"Parakey v$TARGET_VERSION is installed.\"",
            "/usr/bin/open \"$APP_PATH\""
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script missing fragment: \(fragment)")
            }
        }
        for fragment in ["LOG=", ">>\"$LOG\"", ">\"$LOG\"", "prepare_log"] {
            guard !script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script should not reopen a log path: \(fragment)")
            }
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-self-test-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("update helper script should pass bash -n")
        }

        let fm = FileManager.default
        let helperRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-helper-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: helperRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: helperRoot) }

        let helperPath = try writePrivateUpdateHelperScript(script,
                                                            directory: helperRoot.path,
                                                            fileName: "helper.sh")
        var createdStat = stat()
        guard lstat(helperPath, &createdStat) == 0 else {
            throw SelfTestFailure.failed("update helper script file should exist")
        }
        try expect((createdStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper script should be a regular file")
        try expect(Int(createdStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper script should be private to the current user")
        try expect(Int(createdStat.st_nlink),
                   equals: 1,
                   "update helper script should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: URL(fileURLWithPath: helperPath)), encoding: .utf8),
            equals: script,
            "update helper script file should contain the generated script"
        )

        let existing = helperRoot.appendingPathComponent("existing.sh")
        try Data("existing\n".utf8).write(to: existing)
        var existingRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "existing.sh")
        } catch {
            existingRejected = true
        }
        try expect(existingRejected, equals: true,
                   "update helper script writer should reject existing files")
        try expect(
            String(data: try Data(contentsOf: existing), encoding: .utf8),
            equals: "existing\n",
            "update helper script writer should leave existing files untouched"
        )

        let target = helperRoot.appendingPathComponent("target.sh")
        try Data("target\n".utf8).write(to: target)
        let link = helperRoot.appendingPathComponent("linked.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try writePrivateUpdateHelperScript("bad",
                                                   directory: helperRoot.path,
                                                   fileName: "linked.sh")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "update helper script writer should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "update helper script writer should leave symlink targets untouched"
        )

        let preferredLog = helperRoot.appendingPathComponent("SuperDictate-update.log")
        let helperLog = try openPrivateUpdateHelperLog(preferredPath: preferredLog.path,
                                                       fallbackDirectory: helperRoot.path)
        helperLog.handle.write(Data("log\n".utf8))
        helperLog.handle.closeFile()
        try expect(helperLog.path, equals: preferredLog.path,
                   "update helper log should use the preferred path when safe")
        var logStat = stat()
        guard lstat(preferredLog.path, &logStat) == 0 else {
            throw SelfTestFailure.failed("update helper log file should exist")
        }
        try expect((logStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "update helper log should be a regular file")
        try expect(Int(logStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "update helper log should be private to the current user")
        try expect(Int(logStat.st_nlink),
                   equals: 1,
                   "update helper log should not be hard-linked")
        try expect(
            String(data: try Data(contentsOf: preferredLog), encoding: .utf8),
            equals: "log\n",
            "update helper log should receive helper output"
        )

        let linkedLogTarget = helperRoot.appendingPathComponent("linked-log-target.log")
        try Data("target log\n".utf8).write(to: linkedLogTarget)
        let linkedLog = helperRoot.appendingPathComponent("linked-log.log")
        try fm.createSymbolicLink(at: linkedLog, withDestinationURL: linkedLogTarget)
        let fallbackForSymlink = try openPrivateUpdateHelperLog(preferredPath: linkedLog.path,
                                                                fallbackDirectory: helperRoot.path)
        fallbackForSymlink.handle.write(Data("fallback\n".utf8))
        fallbackForSymlink.handle.closeFile()
        try expect(fallbackForSymlink.path == linkedLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is a symlink")
        try expect(
            String(data: try Data(contentsOf: linkedLogTarget), encoding: .utf8),
            equals: "target log\n",
            "update helper log fallback should leave symlink targets untouched"
        )

        let hardLogTarget = helperRoot.appendingPathComponent("hard-log-target.log")
        try Data("hard target\n".utf8).write(to: hardLogTarget)
        let hardLog = helperRoot.appendingPathComponent("hard-log.log")
        try fm.linkItem(at: hardLogTarget, to: hardLog)
        let fallbackForHardLink = try openPrivateUpdateHelperLog(preferredPath: hardLog.path,
                                                                 fallbackDirectory: helperRoot.path)
        fallbackForHardLink.handle.write(Data("hard fallback\n".utf8))
        fallbackForHardLink.handle.closeFile()
        try expect(fallbackForHardLink.path == hardLog.path,
                   equals: false,
                   "update helper log should fall back when preferred path is hard-linked")
        try expect(
            String(data: try Data(contentsOf: hardLogTarget), encoding: .utf8),
            equals: "hard target\n",
            "update helper log fallback should leave hard-linked targets untouched"
        )
    }

    private static func testUpdateProgressState() throws {
        let launch = UpdateProgressLaunch(arguments: [
            UPDATE_PROGRESS_ARGUMENT,
            "/tmp/parakey.state",
            "/tmp/parakey.log",
            "9.8.7",
            "/tmp/\(UPDATE_PROGRESS_APP_PREFIX)test.app",
        ])
        try expect(launch != nil, equals: true,
                   "update progress launch arguments should parse")
        try expect(launch?.targetVersion, equals: Optional("9.8.7"),
                   "update progress launch should retain target version")
        try expect(
            UpdateProgressLaunch(arguments: [UPDATE_PROGRESS_ARGUMENT, "", "/tmp/parakey.log", "9.8.7", "/tmp/app"]) != nil,
            equals: false,
            "update progress launch should reject empty paths"
        )

        let statePath = try createPrivateUpdateProgressStateFile()
        defer { try? FileManager.default.removeItem(atPath: statePath) }

        var st = stat()
        guard lstat(statePath, &st) == 0 else {
            throw SelfTestFailure.failed("update progress state file should exist")
        }
        try expect((st.st_mode & S_IFMT) == S_IFREG, equals: true,
                   "update progress state file should be regular")
        try expect(Int(st.st_nlink), equals: 1,
                   "update progress state file should not be hard-linked")
        try expect(Int(st.st_mode & mode_t(0o777)), equals: 0o600,
                   "update progress state file should be private to the current user")

        let initial = UpdateProgressState.read(from: statePath)
        try expect(initial?.phase, equals: Optional("starting"),
                   "update progress state should default to starting")
        try expect(initial?.message, equals: Optional("Starting update..."),
                   "update progress state should default to the startup message")

        try writePrivateUpdateProgressState(phase: "failed\tbad",
                                            message: "Line 1\nLine 2",
                                            to: statePath)
        let failed = UpdateProgressState.read(from: statePath)
        try expect(failed?.phase, equals: Optional("failed bad"),
                   "update progress state should sanitize tab characters in phases")
        try expect(failed?.message, equals: Optional("Line 1 Line 2"),
                   "update progress state should sanitize newlines in messages")

        let safeCleanupPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)test.app")
        try expect(isSafeUpdateProgressCleanupPath(safeCleanupPath), equals: true,
                   "update progress cleanup should allow copied temp app bundles")
        try expect(isSafeUpdateProgressCleanupPath("/Applications/SuperDictate.app"), equals: false,
                   "update progress cleanup should reject non-temp app bundles")
        let unsafeTempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("Parakey.app")
        try expect(isSafeUpdateProgressCleanupPath(unsafeTempPath), equals: false,
                   "update progress cleanup should reject temp app bundles without the copied-helper prefix")
    }

    private static func testHostileRegistryEnvDetection() throws {
        try expect(
            detectedHostileRegistryEnvVars(in: [:]),
            equals: [],
            "empty environment should not flag any registry override"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["HF_TOKEN": "redacted",
                                                "PATH": "/usr/bin"]),
            equals: [],
            "unrelated env vars (incl. HF_TOKEN) must not flag as hostile"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "https://evil.example/"]),
            equals: ["REGISTRY_URL"],
            "REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["MODEL_REGISTRY_URL": "https://evil.example/"]),
            equals: ["MODEL_REGISTRY_URL"],
            "MODEL_REGISTRY_URL must be flagged"
        )
        try expect(
            detectedHostileRegistryEnvVars(in: ["REGISTRY_URL": "",
                                                "MODEL_REGISTRY_URL": ""]),
            equals: ["MODEL_REGISTRY_URL", "REGISTRY_URL"],
            "an empty-string value still represents a tampered launch env"
        )
    }

    private static func testAudioRouteChangeDecision() throws {
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 1),
            equals: Optional(1 as UInt64),
            "first audio startup failure should retry after one second"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 2),
            equals: Optional(3 as UInt64),
            "second audio startup failure should retry after three seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 3),
            equals: Optional(8 as UInt64),
            "third audio startup failure should retry after eight seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 4),
            equals: UInt64?.none,
            "audio startup should stop retrying after the configured backoff schedule"
        )
        try expect(
            audioRouteChangeAction(isTerminating: true,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .ignore,
            "route changes during termination should be ignored"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: false,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .rebuildMenuOnly,
            "route changes before runtime readiness should only refresh the menu"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: true,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .deferRefresh,
            "route changes during recording should defer the restart"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .restartNow,
            "idle ready route changes should restart audio immediately"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: nil),
            equals: false,
            "configuration changes should not be suppressed without a suppression deadline"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: 11),
            equals: true,
            "configuration changes before the app-owned deadline should be ignored"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 11, suppressedUntil: 11),
            equals: false,
            "configuration changes at the suppression deadline should be handled normally"
        )
    }

    private static func testRecordingLifecycle() throws {
        try expect(
            recordingReleaseAction(capturedSampleCount: 3_999,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0.2499375),
            "release decision should discard clips under the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .transcribe(duration: 0.25),
            "release decision should transcribe clips at the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 0,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0),
            "release decision should handle invalid sample rates defensively"
        )

        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superdictate-recovery-test-\(UUID().uuidString)")
            .appendingPathExtension("sdaudio")
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        let expectedSamples: [Float] = [-0.75, -0.125, 0, 0.25, 0.875]
        let journal = try PendingDictationJournal(url: recoveryURL)
        journal.append(Array(expectedSamples.prefix(2)))
        journal.append(Array(expectedSamples.dropFirst(2)))
        journal.finish()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation journal should round-trip captured samples"
        )
        let recoveryHandle = try FileHandle(forWritingTo: recoveryURL)
        try recoveryHandle.seekToEnd()
        try recoveryHandle.write(contentsOf: Data([0x7f]))
        try recoveryHandle.close()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation recovery should ignore a partial trailing sample after a crash"
        )
        let recoveryAttributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        guard let recoveryMode = recoveryAttributes[.posixPermissions] as? NSNumber else {
            throw SelfTestFailure.failed("pending dictation journal should expose POSIX permissions")
        }
        try expect(
            recoveryMode.intValue,
            equals: 0o600,
            "pending dictation journal should be private"
        )

        let processed = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")],
            removeFillerWords: true
        )
        try expect(
            processed,
            equals: DictationTextProcessingResult(text: "Parakey is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 1),
            "dictation text processing should trim, apply corrections, then remove fillers"
        )

        let preservedFillers = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Parakey")],
            removeFillerWords: false
        )
        try expect(
            preservedFillers,
            equals: DictationTextProcessingResult(text: "Um, Parakey is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 0),
            "dictation text processing should preserve fillers when the setting is off"
        )

        let repairedYo = processedDictationText(
            rawTranscript: "  <unk>лка, мо<UNK> и е<unk>. Потом <unk>жик.  ",
            corrections: [],
            removeFillerWords: false
        )
        try expect(
            repairedYo.text,
            equals: "Ёлка, моё и её. Потом ёжик.",
            "dictation text processing should repair Parakeet unknown tokens used for Cyrillic yo"
        )

        let markerText = systemAudioMuteMarkerText(pid: 12345,
                                                   date: Date(timeIntervalSince1970: 0))
        try expect(
            systemAudioMuteMarkerProcessID(from: markerText),
            equals: Optional(pid_t(12345)),
            "system audio mute marker should preserve the owning pid"
        )
        try expect(
            systemAudioMuteMarkerProcessID(from: "created=bad\n"),
            equals: pid_t?.none,
            "system audio mute marker parsing should ignore missing pids"
        )

        let script = systemAudioMuteWatchdogScript()
        for fragment in [
            #"PID="$1""#,
            #"MARKER="$2""#,
            #"/bin/kill -0 "$PID""#,
            "/usr/bin/osascript -e 'set volume without output muted'",
            #"/bin/rm -f "$MARKER""#,
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("system audio mute watchdog script missing fragment: \(fragment)")
            }
        }

        // Mute command outcome: command failure and verified-unmuted
        // are definitive "not muted"; an ambiguous verification after
        // a successful command must be assumed muted so the recovery
        // marker + watchdog stay armed.
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: true),
            equals: .muted,
            "verified mute should report muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: nil),
            equals: .assumedMuted,
            "successful command with failed verification must assume muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: false),
            equals: .failed,
            "verified-unmuted after the command is a definitive failure"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: true),
            equals: .failed,
            "a failed command is not muted regardless of verification"
        )

        // Probe decision: only a definitive "output is live" while the
        // recording still wants the mute arms recovery and mutes.
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: false),
            equals: .armRecoveryAndMute,
            "live output during an active recording should mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: true, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a user-set mute must not be stomped"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: nil, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a failed probe must not risk stomping an unseen user mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: true),
            equals: .standDown,
            "a recording that already ended should not mute"
        )

        // Mute completion decision: assumed mutes behave exactly like
        // verified mutes (recovery stays armed); a definitive failure
        // disarms; a release that raced the command unmutes at once.
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "verified mute during recording should hold"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "assumed mute must keep recovery armed, not disarm it"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .failed, unmuteAlreadyRequested: false),
            equals: .disarmRecovery,
            "definitive mute failure should disarm marker and watchdog"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during the mute command should unmute immediately"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during an assumed mute should also unmute immediately"
        )

        // Unmute request routing per lifecycle phase.
        try expect(
            systemAudioUnmuteRequestDecision(phase: .idle),
            equals: .nothingToDo,
            "no lifecycle → nothing to unmute"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .probing),
            equals: .deferUntilCommandSettles,
            "release during the probe defers to the probe completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muting),
            equals: .deferUntilCommandSettles,
            "release during the mute command defers to its completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muted),
            equals: .beginUnmute,
            "release while muted unmutes immediately"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .unmuting),
            equals: .nothingToDo,
            "release while an unmute is in flight should not double-issue"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-mute-marker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let marker = root.appendingPathComponent("system-audio-muted")
        try writeSystemAudioMuteMarker(to: marker, text: markerText)
        var markerStat = stat()
        guard lstat(marker.path, &markerStat) == 0 else {
            throw SelfTestFailure.failed("system audio mute marker should exist")
        }
        try expect((markerStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "system audio mute marker should be a regular file")
        try expect(Int(markerStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "system audio mute marker should be private")
        try expect(
            String(data: try Data(contentsOf: marker), encoding: .utf8),
            equals: markerText,
            "system audio mute marker should contain the expected pid"
        )

        let target = root.appendingPathComponent("target-marker")
        try Data("target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("linked-marker")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            try writeSystemAudioMuteMarker(to: symlink, text: "bad\n")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "system audio mute marker should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "system audio mute marker should leave symlink targets untouched"
        )
    }

    private static func testPowerStateRecoveryDecision() throws {
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: true,
                                                isCoreRuntimeReady: true,
                                                isReady: true,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: false,
            "sleep during termination should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: false,
                                                audioIsRunning: false),
            equals: false,
            "sleep before runtime startup should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: true,
            "active recording should schedule wake recovery even if readiness is already down"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: false,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .ignore,
            "wake without a sleep-paused runtime should do nothing"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: true,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during transcription should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: true,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during startup should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .startAudioRuntime,
            "wake after a loaded model should restart audio without reloading the model"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: false),
            equals: .startFullStartup,
            "wake without a loaded model should fall back to full startup"
        )
    }

    private static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )

        try expect(
            state.transition(for: event(.keyDown, keycode: f7.keycode), hotkey: f7, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "recorded F-key keyDown should suppress and press"
        )
    }

    private static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    private static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )
    }

    private static func testHistoryChordShowsOverlay() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        var shiftFirst = HotkeyTransitionState()
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_SHIFT_KEYCODE,
                                             flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "right shift alone should pass through before the history chord is complete"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_COMMAND_KEYCODE,
                                             flags: commandShift),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.showHistory]),
            "right shift then right command should show history without starting dictation"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_COMMAND_KEYCODE,
                                             flags: CGEventFlags.maskShift.rawValue),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .suppressOnly,
            "history chord should suppress the paired right command release"
        )
        try expect(
            shiftFirst.transition(for: event(.flagsChanged,
                                             keycode: RIGHT_SHIFT_KEYCODE,
                                             flags: 0),
                                  hotkey: rightCommand,
                                  triggerMode: .toggle,
                                  isRecording: false),
            equals: .pass,
            "history chord should pass the right shift release when its press was passed through"
        )

        var commandFirst = HotkeyTransitionState()
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskCommand.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right command alone should still start toggle dictation"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_SHIFT_KEYCODE,
                                               flags: commandShift),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.showHistory]),
            "history chord should show history without canceling active dictation"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskShift.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: .suppressOnly,
            "history chord should suppress the paired right command release while recording"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_SHIFT_KEYCODE,
                                               flags: 0),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: .suppressOnly,
            "history chord should suppress the paired right shift release"
        )
        try expect(
            commandFirst.transition(for: event(.flagsChanged,
                                               keycode: RIGHT_COMMAND_KEYCODE,
                                               flags: CGEventFlags.maskCommand.rawValue),
                                    hotkey: rightCommand,
                                    triggerMode: .toggle,
                                    isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right command after the history chord should still stop active dictation"
        )
    }

    private static func testOptionCommandEnterChordStopsWithEnter() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue

        var state = HotkeyTransitionState()
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .suppressOnly,
            "right option should be held for the enter chord while recording"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "right option + right command should stop dictation through the alternate release path"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "enter chord should suppress the paired right command release"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: 0),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "enter chord should suppress the paired right option release"
        )

    }

    private static func testEnterShortcutModeSelection() throws {
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           optionCommandSendsEnter: true),
            equals: false,
            "option-command mode should keep plain command without Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           optionCommandSendsEnter: true),
            equals: true,
            "option-command mode should make option-command press Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           optionCommandSendsEnter: false),
            equals: true,
            "default mode should make plain command press Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           optionCommandSendsEnter: false),
            equals: false,
            "default mode should make option-command finish without Enter"
        )
    }

    private static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    private static func testToggleGatedPressDoesNotFlipToggleState() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        // A press the app would reject (e.g. a transcription in
        // flight) must suppress the key but not flip the toggle —
        // otherwise the next press emits a swallowed .release and
        // only the third press records.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: false),
            equals: .suppressOnly,
            "gated toggle press should suppress without flipping state"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "press after a gated press should start immediately"
        )
        // The stop-side press must NOT be gated: once a recording is
        // active (canStartRecording is false by definition), the
        // press still has to stop it.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: true, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "gate must not block the toggle press that stops a recording"
        )
        // Hold mode ignores the gate entirely — handlePress discarding
        // the press leaves no state behind in hold mode.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "hold-mode press should be unaffected by the gate"
        )
    }

    private static func testEscapePassesThroughWhenNotRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyDown should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape autorepeat should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyUp should pass through when not recording"
        )
    }

    private static func testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.cancel]),
            "Escape keyDown should suppress and cancel while recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "Escape autorepeat from a canceled press should stay suppressed"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "paired Escape keyUp should stay suppressed after cancel"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "later Escape keyUp should pass through once the canceled press is complete"
        )
    }

    private static func event(
        _ type: CGEventType,
        keycode: CGKeyCode,
        flags: UInt64 = 0,
        isAutoRepeat: Bool = false
    ) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(
            typeRawValue: type.rawValue,
            keycode: keycode,
            flagsRawValue: flags,
            isAutoRepeat: isAutoRepeat
        )
    }

    private static func expect<T: Equatable>(
        _ actual: T,
        equals expected: T,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw SelfTestFailure.failed("\(message): got \(actual), expected \(expected)")
        }
    }
}

#endif
