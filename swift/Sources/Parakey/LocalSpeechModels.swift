import Foundation
import Darwin

enum LocalSpeechPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SuperDictate/LocalModels")
    }

    static var script: URL {
        if let bundled = Bundle.main.url(forResource: "local-asr", withExtension: "py") { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/local-asr.py")
    }

    static func python(_ profile: SpeechModelProfile) -> URL {
        root.appendingPathComponent("runtime-v2/bin/python3")
    }

    static func isInstalled(_ profile: SpeechModelProfile) -> Bool {
        guard profile.isExperimental else { return true }
        let marker = root.appendingPathComponent("models/\(profile.rawValue)/ready.json")
        guard FileManager.default.isExecutableFile(atPath: python(profile).path),
              (try? String(contentsOf: root.appendingPathComponent("runtime-v2/runtime-version"), encoding: .utf8)) == "2",
              let data = try? Data(contentsOf: marker),
              let manifest = try? JSONDecoder().decode(LocalModelManifest.self, from: data),
              manifest.version == "1", manifest.key == profile.rawValue,
              !manifest.files.isEmpty else { return false }
        return manifest.files.allSatisfy { entry in
            guard !entry.name.contains("/"), entry.size > 0,
                  let attributes = try? FileManager.default.attributesOfItem(
                    atPath: marker.deletingLastPathComponent().appendingPathComponent(entry.name).path)
            else { return false }
            return (attributes[.size] as? NSNumber)?.int64Value == entry.size
        }
    }

}

private struct LocalModelManifest: Decodable {
    struct File: Decodable { let name: String; let size: Int64 }
    let version: String
    let key: String
    let files: [File]
}

func localSpeechError(_ message: String) -> NSError {
    NSError(domain: "SuperDictate.LocalASR", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct LocalSpeechMessage: Decodable, Sendable {
    var ready: Bool?
    var text: String?
    var error: String?
    var progress: Double?
    var phase: String?
    var downloaded: Int64?
    var total: Int64?
    var speed: Double?
}

// Pipe IO and process state are confined to a dedicated serial queue, never the main actor.
final class LocalSpeechProcess: @unchecked Sendable {
    private let script: URL
    private let queue = DispatchQueue(label: "com.local.superdictate.local-asr", qos: .userInitiated,
                                     autoreleaseFrequency: .workItem)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let cancellationLock = NSLock()
    private var cancellableProcess: Process?
    private var cancelled = false
    private var readBuffer = Data()
    private var temporaryDirectory: URL?

    init(script: URL = LocalSpeechPaths.script) { self.script = script }

    func launch(python: URL, command: String, profile: SpeechModelProfile,
                onMessage: @escaping @Sendable (LocalSpeechMessage) -> Void = { _ in }) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let p = Process()
                    let stdin = Pipe(), stdout = Pipe()
                    try FileManager.default.createDirectory(at: LocalSpeechPaths.root, withIntermediateDirectories: true)
                    let temporaryDirectory = LocalSpeechPaths.root.appendingPathComponent("tmp/session-\(getpid())-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    self.temporaryDirectory = temporaryDirectory
                    let logURL = LocalSpeechPaths.root.appendingPathComponent(command == "serve" ? "worker.log" : "installation.log")
                    if !FileManager.default.fileExists(atPath: logURL.path) {
                        FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                       attributes: [.posixPermissions: 0o600])
                    }
                    let log = try FileHandle(forWritingTo: logURL)
                    try log.truncate(atOffset: 0)
                    defer { try? log.close() }
                    p.executableURL = python
                    p.arguments = ["-u", self.script.path, command,
                                   "--root", LocalSpeechPaths.root.path, "--model", profile.rawValue]
                    p.standardInput = stdin
                    p.standardOutput = stdout
                    p.standardError = log
                    var environment = ProcessInfo.processInfo.environment
                    environment["TOKENIZERS_PARALLELISM"] = "false"
                    environment["PYTHONUNBUFFERED"] = "1"
                    environment["PYTHONNOUSERSITE"] = "1"
                    environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
                    environment["PYTHONDONTWRITEBYTECODE"] = "1"
                    environment["TMPDIR"] = temporaryDirectory.path
                    environment["HF_HOME"] = temporaryDirectory.appendingPathComponent("huggingface").path
                    environment["XDG_CACHE_HOME"] = temporaryDirectory.appendingPathComponent("cache").path
                    environment["NUMBA_CACHE_DIR"] = temporaryDirectory.appendingPathComponent("numba").path
                    environment["PIP_NO_CACHE_DIR"] = "1"
                    environment.removeValue(forKey: "PYTHONHOME")
                    environment.removeValue(forKey: "PYTHONPATH")
                    p.environment = environment
                    try p.run()
                    self.cancellationLock.lock()
                    self.cancellableProcess = p
                    let cancelled = self.cancelled
                    self.cancellationLock.unlock()
                    if cancelled { p.terminate() }
                    self.process = p
                    self.input = stdin.fileHandleForWriting
                    self.output = stdout.fileHandleForReading
                    let timeout = Self.deadline(p, seconds: command == "serve" ? 180 : 3600)
                    defer { timeout.cancel() }
                    while let message = try self.readMessage() {
                        if let error = message.error { throw localSpeechError(error) }
                        onMessage(message)
                        if command == "serve", message.ready == true {
                            continuation.resume()
                            return
                        }
                    }
                    p.waitUntilExit()
                    guard command != "serve", p.terminationStatus == 0,
                          (command == "prepare" || LocalSpeechPaths.isInstalled(profile)) else {
                        throw localSpeechError("Local model process stopped. See LocalModels/worker.log or installation.log.")
                    }
                    self.close()
                    continuation.resume()
                } catch {
                    self.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func request(path: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let p = self.process, p.isRunning, let input = self.input else {
                        throw localSpeechError("Local model is not running. Restart the dictation service.")
                    }
                    struct Request: Encodable { let path: String; let language: String? }
                    var data = try JSONEncoder().encode(Request(path: path.path, language: language))
                    data.append(10)
                    try input.write(contentsOf: data)
                    let timeout = Self.deadline(p, seconds: 600)
                    defer { timeout.cancel() }
                    while let message = try self.readMessage() {
                        if let error = message.error { throw localSpeechError(error) }
                        if let fraction = message.progress { progress(fraction) }
                        if let text = message.text { continuation.resume(returning: text); return }
                    }
                    throw localSpeechError("Local model stopped or timed out. Your recording is retained for recovery.")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readMessage() throws -> LocalSpeechMessage? {
        guard let output else { return nil }
        while true {
            if let newline = readBuffer.firstIndex(of: 10) {
                let line = readBuffer.prefix(upTo: newline)
                let message = try JSONDecoder().decode(LocalSpeechMessage.self, from: line)
                readBuffer.removeSubrange(...newline)
                return message
            }
            let data = output.availableData
            if data.isEmpty { return nil }
            readBuffer.append(data)
            guard readBuffer.count < 4 * 1024 * 1024 else { throw localSpeechError("Invalid local model response") }
        }
    }

    private func close() {
        cancellationLock.lock()
        cancellableProcess = nil
        cancellationLock.unlock()
        try? input?.close()
        if let process, process.isRunning {
            Self.terminate(process)
            process.waitUntilExit()
        }
        try? output?.close()
        process = nil
        input = nil
        output = nil
        readBuffer = Data()
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }

    func stop() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { self.close(); continuation.resume() }
        }
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        if let cancellableProcess { Self.terminate(cancellableProcess) }
        cancellationLock.unlock()
    }

    private static func deadline(_ process: Process, seconds: Double) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak process] in if let process { terminate(process) } }
        timer.resume()
        return timer
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if kill(-pid, SIGTERM) != 0 { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
            guard let process, process.isRunning else { return }
            if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
    }
}

final class LocalSpeechWorker: Sendable {
    let profile: SpeechModelProfile
    private let process = LocalSpeechProcess()
    init(profile: SpeechModelProfile) { self.profile = profile }

    func start() async throws {
        try await Task.detached(priority: .utility) { try LocalSpeechStorage.cleanupAbandonedFiles() }.value
        guard LocalSpeechPaths.isInstalled(profile) else {
            throw localSpeechError("Download this model in Settings before selecting it.")
        }
        try await process.launch(python: LocalSpeechPaths.python(profile), command: "serve", profile: profile)
    }

    func transcribe(samples: [Float], language: String?,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        let directory = LocalSpeechPaths.root.appendingPathComponent("audio-\(getpid())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("\(UUID().uuidString).f32")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }
        guard samples.withUnsafeBytes({ bytes in
            FileManager.default.createFile(atPath: path.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600])
        }) else {
            throw localSpeechError("Could not prepare audio for the local model")
        }
        return try await process.request(path: path, language: language, progress: progress)
    }

    func stop() async { await process.stop() }
}

@MainActor
final class LocalModelDownloads {
    private(set) var profile: SpeechModelProfile?
    private(set) var message: LocalSpeechMessage?
    private(set) var failure: String?
    private(set) var removing = false
    private var task: Task<Void, Never>?
    private var process: LocalSpeechProcess?
    private var operationID = UUID()
    var onChange: (() -> Void)?

    func start(_ selection: SpeechModelProfile) {
        guard task == nil else { return }
        profile = selection
        let operation = UUID()
        operationID = operation
        failure = nil
        message = LocalSpeechMessage(phase: "runtime")
        let process = LocalSpeechProcess()
        self.process = process
        task = Task {
            defer { operationID = UUID(); task = nil; self.process = nil; onChange?() }
            do {
                try await Task.detached(priority: .utility) { try LocalSpeechStorage.cleanupAbandonedFiles() }.value
                let receive: @Sendable (LocalSpeechMessage) -> Void = { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.operationID == operation else { return }
                        self.message = update
                        self.onChange?()
                    }
                }
                let python = try await ManagedSpeechRuntime.ensure(progress: receive)
                try Task.checkCancellation()
                try await process.launch(python: python, command: "install", profile: selection, onMessage: receive)
                try Task.checkCancellation()
                message = LocalSpeechMessage(phase: "ready")
            } catch {
                if Task.isCancelled { message = LocalSpeechMessage(phase: "cancelled") }
                else { failure = error.localizedDescription }
            }
        }
        onChange?()
    }

    var isRunning: Bool { task != nil }

    func remove(_ selection: SpeechModelProfile, active: SpeechModelProfile) {
        guard task == nil, selection.isExperimental, selection != active else { return }
        profile = selection
        operationID = UUID()
        failure = nil
        removing = true
        message = LocalSpeechMessage(phase: "removing")
        task = Task {
            defer { task = nil; removing = false; onChange?() }
            do {
                try await Task.detached(priority: .utility) {
                    try LocalSpeechStorage.remove(selection, active: active)
                }.value
                message = LocalSpeechMessage(phase: "removed")
            } catch { failure = error.localizedDescription }
        }
        onChange?()
    }

    func cancel() {
        process?.cancel()
        task?.cancel()
    }
}
