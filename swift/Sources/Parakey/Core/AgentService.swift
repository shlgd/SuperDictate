// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Core / AgentService.swift

import AppKit
import Foundation

func superDictateApplicationSupportDirectory() throws -> URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
    try FileManager.default.createDirectory(at: url,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

struct AgentRuntimeState: Codable {
    var status: String
    var detail: String
    var updatedAt: TimeInterval
    var pid: Int32
    var isReady: Bool
    var isRecording: Bool
    var isTranscribing: Bool
    var speechModelReady: Bool
    var missingPermissions: [String]
    var hotkeyName: String
    var triggerMode: String
    var downloadProgressFraction: Double?
    var modelDownloadPhase: String?
    var modelDownloadedBytes: Int64?
    var modelDownloadTotalBytes: Int64?
    var modelDownloadBytesPerSecond: Double?
    var modelDownloadEstimatedSecondsRemaining: Double?
    var modelDownloadProgressUpdatedAt: TimeInterval?
}

enum AgentRuntimeStateStore {
    static var url: URL {
        (try? superDictateApplicationSupportDirectory()
            .appendingPathComponent(AGENT_STATUS_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(AGENT_STATUS_FILE_NAME)
    }

    static func write(_ state: AgentRuntimeState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            log("agent state write failed: \(error.localizedDescription)")
        }
    }

    static func read() -> AgentRuntimeState? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AgentRuntimeState.self, from: data)
        } catch {
            return nil
        }
    }
}

enum SuperDictateControlPanelRegistry {
    static var url: URL {
        (try? superDictateApplicationSupportDirectory()
            .appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)
    }

    @MainActor
    static func activateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else {
            return false
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }

    static func terminateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else { return false }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.terminate() {
            return true
        }
        kill(pid, SIGTERM)
        return true
    }

    static func claimCurrentPanel() -> Bool {
        for _ in 0..<2 {
            let fd = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if fd >= 0 {
                do {
                    try writeAllData(Data("\(getpid())\n".utf8), to: fd)
                    guard Darwin.close(fd) == 0 else {
                        _ = Darwin.unlink(url.path)
                        log("control panel pid close failed")
                        return false
                    }
                    return true
                } catch {
                    _ = Darwin.close(fd)
                    _ = Darwin.unlink(url.path)
                    log("control panel pid write failed: \(error.localizedDescription)")
                    return false
                }
            }

            guard errno == EEXIST else {
                log("control panel pid claim failed: \(currentPOSIXError().localizedDescription)")
                return false
            }
            if currentPanelPID() != nil {
                return false
            }
            _ = Darwin.unlink(url.path)
        }
        return false
    }

    static func clearCurrentPanel() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid == getpid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func currentPanelPID() -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid(),
              processIsAlive(pid: pid) else {
            return nil
        }
        return pid
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

struct ProcessRunResult {
    let status: Int32
    let output: String
}

enum SuperDictateAgentService {
    static var launchAgentURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return directory.appendingPathComponent("\(AGENT_LABEL).plist")
    }

    static var launchDomain: String { "gui/\(getuid())" }
    static var launchService: String { "\(launchDomain)/\(AGENT_LABEL)" }

    static func agentExecutablePath() -> String {
        Bundle.main.executablePath ??
        "\(INSTALLED_APP_BUNDLE_PATH)/Contents/MacOS/SuperDictate"
    }

    static func installAndStart() throws {
        try writeLaunchAgentPlist()
        _ = runLaunchctl(["bootstrap", launchDomain, launchAgentURL.path])
        _ = runLaunchctl(["enable", launchService])
        if isAgentRunning() {
            return
        }
        // Never use `kickstart -k` here: opening the control panel while
        // CoreML is still loading must not kill the healthy agent and make
        // Neural Engine preparation start over.
        let kick = runLaunchctl(["kickstart", launchService])
        if kick.status != 0 && !isAgentRunning() {
            throw NSError(domain: "SuperDictateAgentService",
                          code: Int(kick.status),
                          userInfo: [NSLocalizedDescriptionKey: kick.output])
        }
    }

    static func restart() throws {
        stop()
        Thread.sleep(forTimeInterval: 0.35)
        try installAndStart()
    }

    static func stop() {
        _ = runLaunchctl(["bootout", launchDomain, launchAgentURL.path])
        terminateAgentProcesses()
        try? FileManager.default.removeItem(at: launchAgentURL)
        writeStoppedState()
    }

    static func isAgentRunning() -> Bool {
        if let state = AgentRuntimeStateStore.read(),
           state.pid > 0,
           state.pid != getpid(),
           processIsAlive(pid: state.pid) {
            return true
        }
        return !agentProcessIDs().isEmpty
    }

    static func isAgentLoadedOrRunning() -> Bool {
        isAgentRunning() || runLaunchctl(["print", launchService]).status == 0
    }

    static func agentProcessIDs() -> [Int32] {
        let result = run("/usr/bin/pgrep",
                         ["-f", "\(agentExecutablePath()) \(AGENT_ARGUMENT)"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != getpid() }
    }

    private static func writeLaunchAgentPlist() throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let logPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SuperDictate-agent.launchd.log").path
        let plist: [String: Any] = [
            "Label": AGENT_LABEL,
            "ProgramArguments": [agentExecutablePath(), AGENT_ARGUMENT],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: launchAgentURL, options: [.atomic])
    }

    private static func terminateAgentProcesses() {
        for pid in agentProcessIDs() {
            kill(pid, SIGTERM)
        }
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func writeStoppedState() {
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: "stopped",
                              detail: "Dictation service is stopped.",
                              updatedAt: Date().timeIntervalSince1970,
                              pid: 0,
                              isReady: false,
                              isRecording: false,
                              isTranscribing: false,
                              speechModelReady: false,
                              missingPermissions: [],
                              hotkeyName: Settings.shared.configuredHotkey.name,
                              triggerMode: Settings.shared.triggerMode.rawValue)
        )
    }

    private static func runLaunchctl(_ arguments: [String]) -> ProcessRunResult {
        run("/bin/launchctl", arguments)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessRunResult(status: process.terminationStatus,
                                    output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return ProcessRunResult(status: 127, output: error.localizedDescription)
        }
    }
}

let HOSTILE_REGISTRY_ENV_VARS = ["REGISTRY_URL", "MODEL_REGISTRY_URL"]

func detectedHostileRegistryEnvVars(in env: [String: String]) -> [String] {
    HOSTILE_REGISTRY_ENV_VARS.filter { env[$0] != nil }.sorted()
}

@MainActor
func refuseHostileRegistryEnvironmentAndExit() {
    let detected = detectedHostileRegistryEnvVars(in: ProcessInfo.processInfo.environment)
    guard !detected.isEmpty else { return }
    let names = detected.joined(separator: ", ")
    log("refusing to start: registry override env var(s) set: \(names)")
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "SuperDictate refused to start"
    alert.informativeText = """
        These environment variable(s) are set in SuperDictate's process: \(names).

        FluidAudio uses them to override the speech-model download URL. SuperDictate does not support this and treats it as a sign that the launch environment has been tampered with.

        Check ~/Library/LaunchAgents/, your shell rc files, and any parent process. Once the variables are gone, launch SuperDictate again.
        """
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(EXIT_FAILURE)
}
