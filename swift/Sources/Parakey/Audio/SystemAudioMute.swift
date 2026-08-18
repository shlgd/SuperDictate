// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Audio / SystemAudioMute.swift
//
// Mute the system output volume during recording so an open Zoom /
// Music / browser tab doesn't get captured back into the mic and
// transcribed alongside the user's voice.

import AppKit
import Foundation

enum AudioRouteChangeAction: Equatable {
    case ignore
    case rebuildMenuOnly
    case deferRefresh
    case restartNow
}

func audioRouteChangeAction(isTerminating: Bool,
                            isRestartingAudioInput: Bool,
                            isCoreRuntimeReady: Bool,
                            isRecording: Bool,
                            isBusy: Bool,
                            hasStartupTask: Bool) -> AudioRouteChangeAction {
    guard !isTerminating, !isRestartingAudioInput else { return .ignore }
    guard isCoreRuntimeReady else { return .rebuildMenuOnly }
    guard !isRecording, !isBusy, !hasStartupTask else { return .deferRefresh }
    return .restartNow
}

func audioConfigurationChangeIsSuppressed(now: TimeInterval,
                                          suppressedUntil: TimeInterval?) -> Bool {
    guard let suppressedUntil else { return false }
    return now < suppressedUntil
}

enum WakeRuntimeRecoveryAction: Equatable {
    case ignore
    case deferUntilIdle
    case startAudioRuntime
    case startFullStartup
}

func shouldResumeRuntimeAfterSystemSleep(isTerminating: Bool,
                                         isCoreRuntimeReady: Bool,
                                         isReady: Bool,
                                         isRecording: Bool,
                                         audioIsRunning: Bool) -> Bool {
    guard !isTerminating else { return false }
    return isCoreRuntimeReady || isReady || isRecording || audioIsRunning
}

func wakeRuntimeRecoveryAction(shouldResumeAfterWake: Bool,
                               isTerminating: Bool,
                               hasStartupTask: Bool,
                               isBusy: Bool,
                               isSpeechModelReady: Bool) -> WakeRuntimeRecoveryAction {
    guard shouldResumeAfterWake, !isTerminating else { return .ignore }
    guard !hasStartupTask, !isBusy else { return .deferUntilIdle }
    return isSpeechModelReady ? .startAudioRuntime : .startFullStartup
}

enum SystemAudioMuteCommandOutcome: Equatable, Sendable {
    case muted
    case assumedMuted
    case failed
}

func systemAudioMuteCommandOutcome(commandSucceeded: Bool,
                                   verifiedMuted: Bool?) -> SystemAudioMuteCommandOutcome {
    guard commandSucceeded else { return .failed }
    switch verifiedMuted {
    case .some(true): return .muted
    case .none: return .assumedMuted
    case .some(false): return .failed
    }
}

enum SystemAudio {
    private static let queue = DispatchQueue(label: "ParakeySystemAudio", qos: .userInitiated)

    static func mutedState() -> Bool? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: "output muted of (get volume settings)") else {
            return nil
        }
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return nil }
        return result.booleanValue
    }

    static func isMuted() -> Bool { mutedState() == true }

    static func mute() -> SystemAudioMuteCommandOutcome {
        guard let script = NSAppleScript(source: "set volume with output muted") else {
            return systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: nil)
        }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return systemAudioMuteCommandOutcome(commandSucceeded: err == nil,
                                             verifiedMuted: mutedState())
    }

    @discardableResult
    static func unmute() -> Bool {
        var err: NSDictionary?
        _ = NSAppleScript(source: "set volume without output muted")?.executeAndReturnError(&err)
        return err == nil && mutedState() == false
    }

    static func mutedStateAsync(_ completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        queue.async {
            let state = mutedState()
            Task { @MainActor in completion(state) }
        }
    }

    static func muteAsync(_ completion: @escaping @MainActor @Sendable (SystemAudioMuteCommandOutcome) -> Void) {
        queue.async {
            let outcome = mute()
            Task { @MainActor in completion(outcome) }
        }
    }

    static func unmuteAsync(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let unmuted = unmute()
            Task { @MainActor in completion(unmuted) }
        }
    }
}

enum SystemAudioMutePhase: Equatable, Sendable {
    case idle
    case probing
    case muting
    case muted
    case unmuting
}

enum SystemAudioMuteProbeDecision: Equatable, Sendable {
    case standDown
    case armRecoveryAndMute
}

func systemAudioMuteProbeDecision(mutedState: Bool?,
                                  unmuteAlreadyRequested: Bool) -> SystemAudioMuteProbeDecision {
    guard mutedState == false, !unmuteAlreadyRequested else { return .standDown }
    return .armRecoveryAndMute
}

enum SystemAudioMuteCommandDecision: Equatable, Sendable {
    case disarmRecovery
    case stayMuted
    case beginUnmute
}

func systemAudioMuteCommandDecision(outcome: SystemAudioMuteCommandOutcome,
                                    unmuteAlreadyRequested: Bool) -> SystemAudioMuteCommandDecision {
    switch outcome {
    case .failed:
        return .disarmRecovery
    case .muted, .assumedMuted:
        return unmuteAlreadyRequested ? .beginUnmute : .stayMuted
    }
}

enum SystemAudioUnmuteRequestDecision: Equatable, Sendable {
    case nothingToDo
    case deferUntilCommandSettles
    case beginUnmute
}

func systemAudioUnmuteRequestDecision(phase: SystemAudioMutePhase) -> SystemAudioUnmuteRequestDecision {
    switch phase {
    case .idle, .unmuting: return .nothingToDo
    case .probing, .muting: return .deferUntilCommandSettles
    case .muted: return .beginUnmute
    }
}

func systemAudioMuteMarkerURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
        .appendingPathComponent("system-audio-muted", isDirectory: false)
}

func systemAudioMuteMarkerText(pid: pid_t = getpid(), date: Date = Date()) -> String {
    """
    pid=\(pid)
    created=\(ISO8601DateFormatter().string(from: date))
    """
}

func systemAudioMuteMarkerProcessID(from text: String) -> pid_t? {
    for line in text.split(separator: "\n") {
        guard line.hasPrefix("pid="),
              let raw = Int32(line.dropFirst(4)),
              raw > 0 else { continue }
        return raw
    }
    return nil
}

func writeSystemAudioMuteMarker(to url: URL = systemAudioMuteMarkerURL(),
                                text: String = systemAudioMuteMarkerText()) throws {
    let fm = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fm.createDirectory(at: directory,
                           withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])

    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { Darwin.close(fd) }
    try text.withCString { raw in
        let data = UnsafeRawPointer(raw)
        let count = strlen(raw)
        var written = 0
        while written < count {
            let n = Darwin.write(fd, data.advanced(by: written), count - written)
            guard n >= 0 else { throw currentPOSIXError() }
            written += n
        }
    }
    _ = Darwin.fchmod(fd, 0o600)
}

func removeSystemAudioMuteMarker(at url: URL = systemAudioMuteMarkerURL()) {
    try? FileManager.default.removeItem(at: url)
}

func systemAudioMuteWatchdogScript() -> String {
    #"""
    PID="$1"
    MARKER="$2"

    while /bin/kill -0 "$PID" 2>/dev/null; do
        /bin/sleep 0.5
    done

    if [ -e "$MARKER" ]; then
        /usr/bin/osascript -e 'set volume without output muted' >/dev/null 2>&1 || true
        /bin/rm -f "$MARKER"
    fi
    """#
}

// MARK: - Sounds

@MainActor
enum Sounds {
    private static let start = systemSound("Tink", volume: 0.55)
    private static let done = systemSound("Pop", volume: 0.45)
    private static let error = systemSound("Basso", volume: 0.30)

    private static func systemSound(_ name: String, volume: Float) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else { return nil }
        sound.volume = volume
        return sound
    }

    static func playStart() { start?.stop(); start?.play() }
    static func playDone()  { done?.stop();  done?.play() }
    static func playError() { error?.stop(); error?.play() }
}
