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

#if DEBUG
extension LocalModelDownloads {
    static func testLifecycle() throws {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var attempts = 0
            var late: (@Sendable (LocalSpeechMessage) -> Void)?
        }
        let probe = Probe()
        let downloads = LocalModelDownloads { _, _, receive in
            let attempt = probe.lock.withLock { probe.attempts += 1; return probe.attempts }
            receive(LocalSpeechMessage(phase: "runtime-packages"))
            if attempt == 3 {
                probe.lock.withLock { probe.late = receive }
                try await Task.sleep(for: .seconds(30))
            } else {
                try await Task.sleep(for: .milliseconds(30))
            }
            if attempt == 1 { throw localSpeechError("fixture offline") }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard condition() else { throw localSpeechError("Download lifecycle test timed out") }
        }
        downloads.start(.whisperTurbo)
        guard downloads.message?.phase == "storage", !downloads.waitingForProgress else {
            throw localSpeechError("Initial storage status must be immediate")
        }
        downloads.lastProgressAt = Date().addingTimeInterval(-35)
        guard downloads.waitingForProgress, downloads.secondsWithoutProgress >= 35 else {
            throw localSpeechError("Missing stalled-stage feedback")
        }
        downloads.start(.qwenSmall)
        try wait { !downloads.isRunning }
        guard downloads.profile == .whisperTurbo, downloads.failure == "fixture offline",
              probe.lock.withLock({ probe.attempts }) == 1 else {
            throw localSpeechError("Duplicate click or failure recovery is broken")
        }
        downloads.start(.whisperTurbo)
        guard downloads.failure == nil, downloads.failureCategory == nil, !downloads.waitingForProgress else {
            throw localSpeechError("Retry retained old error or stalled state")
        }
        try wait { !downloads.isRunning }
        guard downloads.message?.phase == "ready" else { throw localSpeechError("Retry did not complete") }
        downloads.start(.whisperTurbo)
        try wait { probe.lock.withLock { probe.late != nil } }
        downloads.cancel()
        downloads.cancel()
        guard downloads.isCancelling, downloads.message?.phase == "cancelling" else {
            throw localSpeechError("Cancellation was not immediately visible")
        }
        let late = probe.lock.withLock { probe.late }
        late?(LocalSpeechMessage(phase: "downloading", downloaded: 99))
        try wait { !downloads.isRunning }
        guard downloads.message?.phase == "cancelled", !downloads.isCancelling else {
            throw localSpeechError("Cancelled download remained busy")
        }
        downloads.start(.qwenSmall)
        late?(LocalSpeechMessage(phase: "obsolete", downloaded: 123))
        try wait { !downloads.isRunning }
        guard downloads.profile == .qwenSmall, downloads.message?.phase == "ready",
              downloads.failure == nil else { throw localSpeechError("Late callback corrupted retry") }
    }
}
#endif

private struct LocalModelManifest: Decodable {
    struct File: Decodable { let name: String; let size: Int64 }
    let version: String
    let key: String
    let files: [File]
}

func localSpeechError(_ message: String, category: DownloadFailure = .unknown, code: Int = 1) -> NSError {
    NSError(domain: "SuperDictate.LocalASR", code: code,
            userInfo: [NSLocalizedDescriptionKey: message, "downloadFailure": category.rawValue])
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
    var failure_code: String?
    var code: Int?
    var retry: Int?
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
                    guard !self.cancellationLock.withLock({ self.cancelled }) else { throw CancellationError() }
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
                    p.arguments = ["-I", "-B", "-u", self.script.path, command,
                                   "--root", LocalSpeechPaths.root.path, "--model", profile.rawValue]
                    p.standardInput = stdin
                    p.standardOutput = stdout
                    p.standardError = log
                    p.environment = LocalSpeechEnvironment.make(temporaryDirectory: temporaryDirectory)
                    try p.run()
                    self.cancellationLock.lock()
                    self.cancellableProcess = p
                    let cancelled = self.cancelled
                    self.cancellationLock.unlock()
                    if cancelled { Self.terminate(p) }
                    self.process = p
                    self.input = stdin.fileHandleForWriting
                    self.output = stdout.fileHandleForReading
                    let timeout = Self.deadline(p, seconds: command == "serve" ? 180 : 3600)
                    defer { timeout.cancel() }
                    while let message = try self.readMessage() {
                        if let error = message.error {
                            throw localSpeechError(error, category: message.failure_code.flatMap(DownloadFailure.init(rawValue:)) ?? .unknown,
                                                   code: message.code ?? 1)
                        }
                        onMessage(message)
                        if command == "serve", message.ready == true {
                            continuation.resume()
                            return
                        }
                    }
                    p.waitUntilExit()
                    guard command != "serve", p.terminationStatus == 0,
                          (command == "prepare" || LocalSpeechPaths.isInstalled(profile)) else {
                        throw localSpeechError("Local model process stopped. See LocalModels/worker.log or installation.log.",
                                               category: .process, code: Int(p.terminationStatus))
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

typealias LocalModelInstallation = @Sendable (SpeechModelProfile, LocalSpeechProcess,
    @escaping @Sendable (LocalSpeechMessage) -> Void) async throws -> Void

@MainActor
final class LocalModelDownloads {
    private(set) var profile: SpeechModelProfile?
    private(set) var message: LocalSpeechMessage?
    private(set) var failure: String?
    private(set) var failureCategory: DownloadFailure?
    private(set) var removing = false
    private(set) var isCancelling = false
    private let install: LocalModelInstallation
    private var task: Task<Void, Never>?
    private var process: LocalSpeechProcess?
    private var operationID = UUID()
    private var startedAt: Date?
    private var lastProgressAt = Date()
    var elapsedSeconds: Int { Int(max(0, Date().timeIntervalSince(startedAt ?? Date()))) }
    var waitingForProgress: Bool { isRunning && Date().timeIntervalSince(lastProgressAt) >= 30 }
    var secondsWithoutProgress: Int { Int(max(0, Date().timeIntervalSince(lastProgressAt))) }
    var onChange: (() -> Void)?

    init(install: @escaping LocalModelInstallation = LocalModelDownloads.installModel) {
        self.install = install
    }

    nonisolated private static func installModel(_ selection: SpeechModelProfile, _ process: LocalSpeechProcess,
                                                 _ receive: @escaping @Sendable (LocalSpeechMessage) -> Void) async throws {
        log("local model download stage: storage-cleanup")
        DownloadDiagnostics.shared.record(.stage, model: selection, stage: .storage)
        receive(LocalSpeechMessage(phase: "storage"))
        try await Task.detached(priority: .utility) { try LocalSpeechStorage.cleanupAbandonedFiles() }.value
        try Task.checkCancellation()
        log("local model download stage: interpreter-prepare")
        DownloadDiagnostics.shared.record(.stage, model: selection, stage: .interpreterPrepare)
        receive(LocalSpeechMessage(phase: "interpreter-prepare"))
        let python = try await ManagedSpeechRuntime.ensure(progress: receive)
        try Task.checkCancellation()
        log("local model download stage: installer-launch")
        DownloadDiagnostics.shared.record(.stage, model: selection, stage: .installerLaunch)
        receive(LocalSpeechMessage(phase: "installer-launch"))
        try await process.launch(python: python, command: "install", profile: selection, onMessage: receive)
    }

    func start(_ selection: SpeechModelProfile) {
        guard task == nil else {
            log("local model download: existing operation shown instead of starting a duplicate")
            DownloadDiagnostics.shared.record(.duplicate, model: selection)
            onChange?()
            return
        }
        log("local model download starting: \(selection.rawValue)")
        DownloadDiagnostics.shared.record(.start, model: selection)
        profile = selection
        let operation = UUID()
        operationID = operation
        failure = nil
        failureCategory = nil
        startedAt = Date()
        lastProgressAt = Date()
        message = LocalSpeechMessage(phase: "storage")
        let process = LocalSpeechProcess()
        self.process = process
        task = Task {
            let heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, self.operationID == operation else { return }
                    log("local model download waiting: model=\(selection.rawValue) phase=\(self.message?.phase ?? "unknown") elapsed=\(self.elapsedSeconds)s bytes=\(self.message?.downloaded ?? 0)/\(self.message?.total ?? 0)")
                    DownloadDiagnostics.shared.record(.progress, model: selection,
                        stage: self.message?.phase.flatMap(DownloadStage.init(rawValue:)) ?? .unknown,
                        elapsed: self.elapsedSeconds, bytes: self.message?.downloaded, total: self.message?.total)
                    self.onChange?()
                }
            }
            defer { heartbeat.cancel(); operationID = UUID(); task = nil; self.process = nil; isCancelling = false; onChange?() }
            do {
                try Task.checkCancellation()
                let receive: @Sendable (LocalSpeechMessage) -> Void = { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.operationID == operation, !self.isCancelling else { return }
                        if self.message?.phase != update.phase {
                            log("local model download stage: \(update.phase ?? "unknown")")
                            DownloadDiagnostics.shared.record(.stage, model: selection,
                                stage: update.phase.flatMap(DownloadStage.init(rawValue:)) ?? .unknown, elapsed: self.elapsedSeconds)
                        }
                        if let retry = update.retry {
                            DownloadDiagnostics.shared.record(.retry, model: selection,
                                stage: update.phase.flatMap(DownloadStage.init(rawValue:)) ?? .unknown,
                                elapsed: self.elapsedSeconds, failure: update.failure_code.flatMap(DownloadFailure.init(rawValue:)) ?? .unknown,
                                code: update.code ?? retry)
                        }
                        if self.message?.phase != update.phase || self.message?.downloaded != update.downloaded {
                            self.lastProgressAt = Date()
                        }
                        self.message = update
                        self.onChange?()
                    }
                }
                try await install(selection, process, receive)
                try Task.checkCancellation()
                message = LocalSpeechMessage(phase: "ready")
                log("local model download completed: \(selection.rawValue) elapsed=\(elapsedSeconds)s")
                DownloadDiagnostics.shared.record(.completed, model: selection, elapsed: elapsedSeconds)
            } catch {
                if Task.isCancelled {
                    message = LocalSpeechMessage(phase: "cancelled")
                    log("local model download cancelled: \(selection.rawValue)")
                    DownloadDiagnostics.shared.record(.cancelled, model: selection, elapsed: elapsedSeconds)
                } else {
                    failure = error.localizedDescription
                    failureCategory = DownloadFailure.classify(error)
                    log("local model download failed: \(selection.rawValue): \(error.localizedDescription)")
                    DownloadDiagnostics.shared.record(.failed, model: selection,
                        stage: message?.phase.flatMap(DownloadStage.init(rawValue:)) ?? .unknown,
                        elapsed: elapsedSeconds, failure: DownloadFailure.classify(error), code: (error as NSError).code)
                }
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
        failureCategory = nil
        removing = true
        message = LocalSpeechMessage(phase: "removing")
        task = Task {
            defer { task = nil; removing = false; onChange?() }
            do {
                try await Task.detached(priority: .utility) {
                    try LocalSpeechStorage.remove(selection, active: active)
                }.value
                message = LocalSpeechMessage(phase: "removed")
            } catch {
                failure = error.localizedDescription
                failureCategory = DownloadFailure.classify(error)
            }
        }
        onChange?()
    }

    func cancel() {
        guard isRunning, !removing, !isCancelling else { return }
        isCancelling = true
        DownloadDiagnostics.shared.record(.cancel, model: profile, elapsed: elapsedSeconds)
        message = LocalSpeechMessage(phase: "cancelling")
        process?.cancel()
        task?.cancel()
        onChange?()
    }
}
