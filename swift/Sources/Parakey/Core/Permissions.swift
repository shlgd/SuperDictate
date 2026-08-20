// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Core / Permissions.swift

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Permissions

enum Permission: String, CaseIterable, Equatable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
}

enum ReadinessTransition: Equatable {
    case rebuildMenuOnly
    case blockForPermissions([Permission])
    case startHotkeyListener
}

func readinessTransition(
    isReady: Bool,
    isCoreRuntimeReady: Bool,
    missingPermissions: [Permission]
) -> ReadinessTransition {
    if isReady {
        return missingPermissions.isEmpty
            ? .rebuildMenuOnly
            : .blockForPermissions(missingPermissions)
    }

    guard isCoreRuntimeReady else {
        return .rebuildMenuOnly
    }

    return missingPermissions.isEmpty
        ? .startHotkeyListener
        : .blockForPermissions(missingPermissions)
}

enum StartupFailureStage {
    case speechModel
    case audioInput
    case hotkeyListener

    var statusTitle: String {
        switch self {
        case .speechModel: return "Speech model failed to load"
        case .audioInput: return "Audio input failed to start"
        case .hotkeyListener: return "Hotkey listener failed to start"
        }
    }

    var retryTitle: String {
        switch self {
        case .speechModel: return "Retry Loading Speech Model"
        case .audioInput: return "Retry Audio Startup"
        case .hotkeyListener: return "Retry Hotkey Startup"
        }
    }
}

struct StartupFailure {
    let stage: StartupFailureStage
    let detail: String

    var statusTitle: String { stage.statusTitle }
    var retryTitle: String { stage.retryTitle }
}

enum PreviousExitNoticeAction: Equatable {
    case none
    case showNotice
}

func previousExitNoticeAction(previousRunWasActive: Bool) -> PreviousExitNoticeAction {
    previousRunWasActive ? .showNotice : .none
}

func speechModelFailureDetail(errorDescription: String) -> String {
    let lower = errorDescription.lowercased()
    let looksLikeIntegrityFailure = [
        "sha",
        "hash",
        "integrity",
        "verification",
        "verified",
        "corrupt",
        "incomplete",
    ].contains { lower.contains($0) }
    let looksLikeNetworkFailure = [
        "download",
        "network",
        "internet",
        "offline",
        "timed out",
        "timeout",
        "could not connect",
        "cannot connect",
        "not connected",
        "host",
        "url",
    ].contains { lower.contains($0) }
    let looksLikeDiskSpaceFailure = [
        "disk space",
        "free some disk",
        "available:",
        "needed:",
    ].contains { lower.contains($0) }

    if looksLikeDiskSpaceFailure {
        return errorDescription
    }

    if looksLikeIntegrityFailure {
        return """
        \(errorDescription)

        The local speech model cache may be incomplete or corrupt. Use Support → Reset Speech Model Cache… to delete it and download a fresh verified copy.
        """
    }
    if looksLikeNetworkFailure {
        return """
        \(errorDescription)

        Parakey needs a one-time download of the local speech model. Check your network connection and retry; audio is not uploaded.
        """
    }
    return """
    \(errorDescription)

    If this keeps happening, use Support → Reset Speech Model Cache… to download a fresh verified copy, then Copy Diagnostics for a GitHub issue.
    """
}

private func fourCharacterCodeString(forRawOSStatus raw: UInt32) -> String? {
    let bytes = [
        UInt8((raw >> 24) & 0xff),
        UInt8((raw >> 16) & 0xff),
        UInt8((raw >> 8) & 0xff),
        UInt8(raw & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
    return String(bytes: bytes, encoding: .ascii)
}

func formattedOSStatusCode(_ code: Int) -> String {
    let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: code))
    let hex = String(format: "0x%08x", raw)
    if let fourCharacterCode = fourCharacterCodeString(forRawOSStatus: raw) {
        return "OSStatus \(code) (\(hex), '\(fourCharacterCode)')"
    }
    return "OSStatus \(code) (\(hex))"
}

func formattedOSStatus(_ status: OSStatus) -> String {
    formattedOSStatusCode(Int(status))
}

func coreAudioOSStatusCode(from error: NSError) -> Int? {
    let domain = error.domain.lowercased()
    guard error.domain == NSOSStatusErrorDomain
        || domain.contains("coreaudio")
        || domain.contains("avfaudio") else {
        return nil
    }
    return error.code
}

private func stringValue(fromUserInfoValue value: Any?) -> String? {
    guard let value else { return nil }
    let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty || text == "nil" ? nil : text
}

func failedAudioCallDescription(from error: NSError) -> String? {
    for key in ["failed call", "failedCall", "AVAudioEngineFailedCall"] {
        if let text = stringValue(fromUserInfoValue: error.userInfo[key]) {
            return text
        }
    }

    for (key, value) in error.userInfo {
        let lower = key.lowercased()
        guard lower.contains("failed"), lower.contains("call") else { continue }
        if let text = stringValue(fromUserInfoValue: value) {
            return text
        }
    }
    return nil
}

func audioStartupErrorDescription(_ error: Error) -> String {
    let nsError = error as NSError
    var lines = [nsError.localizedDescription]
    if let statusCode = coreAudioOSStatusCode(from: nsError) {
        lines.append("CoreAudio \(formattedOSStatusCode(statusCode)).")
    }
    if let failedCall = failedAudioCallDescription(from: nsError) {
        lines.append("Failed call: \(failedCall).")
    }
    return lines.joined(separator: "\n")
}

func singleLineLogDetail(_ text: String) -> String {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

func audioInputFailureDetail(errorDescription: String) -> String {
    let lower = errorDescription.lowercased()
    let looksLikeCoreAudioFailure = lower.contains("coreaudio")
        || lower.contains("avfaudio")
        || lower.contains("osstatus")
        || lower.contains("kaustartio")
    guard looksLikeCoreAudioFailure else { return errorDescription }

    return """
    \(errorDescription)

    Parakey rebuilt the audio engine and retried microphone startup, but CoreAudio is still refusing to start the input unit. If this began after sleep/wake or an audio-device change, restart CoreAudio with sudo killall coreaudiod or reboot the Mac, then retry audio startup.
    """
}

func startupFailureDetail(stage: StartupFailureStage, errorDescription: String) -> String {
    switch stage {
    case .speechModel:
        return speechModelFailureDetail(errorDescription: errorDescription)
    case .audioInput:
        return audioInputFailureDetail(errorDescription: errorDescription)
    case .hotkeyListener:
        return errorDescription
    }
}

func startupFailureDetail(stage: StartupFailureStage, error: Error) -> String {
    let errorDescription = stage == .audioInput
        ? audioStartupErrorDescription(error)
        : error.localizedDescription
    return startupFailureDetail(stage: stage, errorDescription: errorDescription)
}

func startupFailureLogDetail(stage: StartupFailureStage, error: Error) -> String {
    let detail = stage == .audioInput
        ? audioStartupErrorDescription(error)
        : String(describing: error)
    return singleLineLogDetail(detail)
}

func audioStartupRetryDelaySeconds(afterFailedAttempt failedAttempt: Int,
                                   retryDelays: [UInt64] = AUDIO_START_RETRY_DELAYS_SECONDS) -> UInt64? {
    guard failedAttempt > 0, failedAttempt <= retryDelays.count else { return nil }
    return retryDelays[failedAttempt - 1]
}

func audioStartupRetryStatusTitle(nextAttempt: Int,
                                  totalAttempts: Int,
                                  delaySeconds: UInt64) -> String {
    "Audio input failed; retrying in \(delaySeconds)s (\(nextAttempt)/\(totalAttempts))…"
}

struct SetupChecklistRowState: Equatable {
    let detail: String
    let status: String
    let buttonTitle: String?
}

func speechModelSetupRowState(profile: SpeechModelProfile,
                              isSpeechModelReady: Bool,
                              isStartupInProgress: Bool,
                              startupStatusTitle: String,
                              failure: StartupFailure?) -> SetupChecklistRowState {
    if let failure, failure.stage == .speechModel {
        return SetupChecklistRowState(detail: failure.detail,
                                      status: "Needs retry",
                                      buttonTitle: "Retry")
    }
    if isSpeechModelReady {
        return SetupChecklistRowState(detail: profile.setupReadyDetail,
                                      status: "Ready",
                                      buttonTitle: nil)
    }
    if isStartupInProgress {
        return SetupChecklistRowState(detail: startupStatusTitle,
                                      status: "Loading",
                                      buttonTitle: nil)
    }
    return SetupChecklistRowState(detail: "The speech model loads before dictation can start.",
                                  status: "Waiting",
                                  buttonTitle: nil)
}

func audioInputSetupRowState(isSpeechModelReady: Bool,
                             isCoreRuntimeReady: Bool,
                             isStartupInProgress: Bool,
                             startupStatusTitle: String = "Starting audio input…",
                             failure: StartupFailure?) -> SetupChecklistRowState {
    if let failure, failure.stage == .audioInput {
        return SetupChecklistRowState(detail: failure.detail,
                                      status: "Needs retry",
                                      buttonTitle: "Retry")
    }
    if isCoreRuntimeReady {
        return SetupChecklistRowState(detail: "Microphone capture is ready.",
                                      status: "Ready",
                                      buttonTitle: nil)
    }
    if !isSpeechModelReady {
        return SetupChecklistRowState(detail: "Available after the speech model loads.",
                                      status: "Waiting",
                                      buttonTitle: nil)
    }
    if isStartupInProgress {
        return SetupChecklistRowState(detail: startupStatusTitle,
                                      status: "Starting",
                                      buttonTitle: nil)
    }
    return SetupChecklistRowState(detail: "Audio input starts before dictation can begin.",
                                  status: "Waiting",
                                  buttonTitle: nil)
}

func hotkeySetupRowState(isReady: Bool,
                         hotkeyTestSucceeded: Bool,
                         triggerMode: TriggerMode,
                         hotkeyName: String,
                         failure: StartupFailure?) -> SetupChecklistRowState {
    if let failure, failure.stage == .hotkeyListener {
        return SetupChecklistRowState(detail: failure.detail,
                                      status: "Needs retry",
                                      buttonTitle: "Retry")
    }

    let verb = triggerMode == .hold ? "Hold" : "Press"
    if !isReady {
        return SetupChecklistRowState(detail: "Available after the model, audio input, and permissions are ready.",
                                      status: "Waiting",
                                      buttonTitle: nil)
    }
    if hotkeyTestSucceeded {
        return SetupChecklistRowState(detail: "\(verb) \(hotkeyName) to dictate.",
                                      status: "Detected",
                                      buttonTitle: nil)
    }
    return SetupChecklistRowState(detail: "\(verb) \(hotkeyName). A quick tap is enough to confirm the hotkey.",
                                  status: "Ready to test",
                                  buttonTitle: nil)
}

@MainActor
final class Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        }
    }

    /// Trigger the system prompt or, if previously denied, push the
    /// user toward the right Settings pane. Returns immediately;
    /// actual grant happens asynchronously.
    static func request(_ p: Permission) {
        switch p {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied {
                openSettings(for: p)
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    log("Microphone request: granted=\(granted)")
                }
            }
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt"
            _ = AXIsProcessTrustedWithOptions([key: kCFBooleanTrue!] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    static func openSettings(for permission: Permission) {
        let subpath: String
        switch permission {
        case .microphone:
            subpath = "Privacy_Microphone"
        case .accessibility:
            subpath = "Privacy_Accessibility"
        case .inputMonitoring:
            subpath = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(subpath)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Revoke every macOS permission the app holds via `tccutil reset`.
    /// Only ever called from an explicit, confirmed action in Settings —
    /// never automatically.
    nonisolated static func resetAll() -> [String] {
        let services: [Permission: String] = [
            .microphone: "Microphone",
            .accessibility: "Accessibility",
            .inputMonitoring: "ListenEvent",
        ]
        var failures: [String] = []
        for permission in Permission.allCases {
            guard let service = services[permission] else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, SETTINGS_SUITE]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    log("Permissions.resetAll: tccutil reset \(service) exited \(process.terminationStatus)")
                    failures.append(service)
                }
            } catch {
                log("Permissions.resetAll: tccutil reset \(service) failed: \(error.localizedDescription)")
                failures.append(service)
            }
        }
        return failures
    }
}
