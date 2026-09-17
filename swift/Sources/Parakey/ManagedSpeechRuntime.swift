import CryptoKit
import Darwin
import Foundation

enum ManagedSpeechRuntime {
    static let distribution = "cpython-3.11.16-20260901"
    static let archiveSHA256 = "50424fa409e8ae84b82a3052522f64695b47dff2158b70bb7358e0ebd6c085c9"
    static let archiveURL = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.11.16%2B20260901-aarch64-apple-darwin-install_only.tar.gz")!

    static func ensure(root: URL = LocalSpeechPaths.root,
                       progress: @escaping @Sendable (LocalSpeechMessage) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = root.appendingPathComponent(distribution)
        let python = destination.appendingPathComponent("bin/python3")
        let marker = destination.appendingPathComponent(".verified")
        if fm.isExecutableFile(atPath: python.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == archiveSHA256 { return python }

        let descriptor = open(root.appendingPathComponent(".bootstrap.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw localSpeechError("Cannot lock the local runtime directory") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw localSpeechError("Local runtime installation is already in progress")
        }
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (values.volumeAvailableCapacityForImportantUsage ?? 0) > 2_000_000_000 else {
            throw localSpeechError("At least 2 GB of free disk space is needed to prepare the speech runtime", category: .diskSpace)
        }
        // Only incomplete staging directories are removed, under the cross-process lock.
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".python-stage-") {
            try fm.removeItem(at: entry)
        }
        let stage = root.appendingPathComponent(".python-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        progress(LocalSpeechMessage(phase: "interpreter"))
        let archive = stage.appendingPathComponent("runtime.tar.gz")
        let transfer = RuntimeDownloadProgress(destination: archive, progress: progress)
        try await transfer.download(archiveURL)
        try Task.checkCancellation()
        progress(LocalSpeechMessage(phase: "runtime-verifying"))
        try await Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: archive)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == archiveSHA256 else {
                throw localSpeechError("Speech runtime checksum mismatch", category: .checksum)
            }
        }.value
        try Task.checkCancellation()
        try await RuntimeExtraction().run(executable: "/usr/bin/tar",
                                          arguments: ["-xzf", archive.path, "-C", stage.path])
        try Task.checkCancellation()
        let unpacked = stage.appendingPathComponent("python")
        guard fm.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/python3").path) else {
            throw localSpeechError("The speech runtime archive is incomplete")
        }
        try archiveSHA256.write(to: unpacked.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: unpacked, to: destination)
        return python
    }
}

final class RuntimeExtraction: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    func run(executable: String, arguments: [String], timeout: TimeInterval = 60) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try lock.withLock {
                    guard !cancelled else { throw CancellationError() }
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                }
                let deadline = DispatchWorkItem { [self] in stop() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                defer { deadline.cancel() }
                process.waitUntilExit()
                if lock.withLock({ cancelled }) { throw CancellationError() }
                guard process.terminationStatus == 0 else {
                    throw localSpeechError("Runtime extraction failed or timed out. Retry installation.")
                }
            }.value
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.stop()
        }
    }

    private func stop() {
        lock.withLock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

#if DEBUG
extension ManagedSpeechRuntime {
    static func testNetworkLifecycle() async throws {
        try await RuntimeExtraction().run(executable: "/usr/bin/true", arguments: [])
        do {
            try await RuntimeExtraction().run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.1)
            throw localSpeechError("Extraction deadline did not fire")
        } catch {
            guard error.localizedDescription.contains("extraction failed") else { throw error }
        }
        let extraction = Task { try await RuntimeExtraction().run(executable: "/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(50))
        extraction.cancel()
        do { try await extraction.value; throw localSpeechError("Extraction cancellation failed") }
        catch is CancellationError { }
        print("PASS extraction success, deadline, cancellation")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/runtime-download-fixture.py")
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", fixture.path]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        guard let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8),
              let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw localSpeechError("HTTP fixture failed to start")
        }
        for route in ["ok", "error", "hang", "partial", "cancel", "ok"] {
            let destination = directory.appendingPathComponent(UUID().uuidString)
            let download = RuntimeDownloadProgress(destination: destination, requestTimeout: 0.5,
                                                   resourceTimeout: 2, progress: { _ in })
            let url = URL(string: "http://127.0.0.1:\(port)/\(route == "cancel" ? "hang" : route)")!
            let task = Task { try await download.download(url) }
            if route == "cancel" {
                try await Task.sleep(for: .milliseconds(100))
                task.cancel()
            }
            var failure: Error?
            do { try await task.value } catch { failure = error }
            if route == "ok" {
                guard failure == nil, try Data(contentsOf: destination).count == 65536 else {
                    throw localSpeechError("Successful HTTP download failed: \(String(describing: failure))")
                }
            } else {
                guard failure != nil, !FileManager.default.fileExists(atPath: destination.path) else {
                    throw localSpeechError("Failed HTTP transfer published a file: \(route)")
                }
                if route == "error", failure?.localizedDescription.contains("503") != true {
                    throw localSpeechError("HTTP status was lost")
                }
            }
            print("PASS runtime HTTP \(route)")
        }
    }
}
#endif

final class RuntimeDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (LocalSpeechMessage) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private let started = Date()
    private var lastUpdate = Date.distantPast
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    init(destination: URL, requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 600,
         progress: @escaping @Sendable (LocalSpeechMessage) -> Void) {
        self.destination = destination
        self.progress = progress
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
    func download(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = requestTimeout
                configuration.timeoutIntervalForResource = resourceTimeout
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.task?.cancel()
            self.lock.unlock()
        }
    }
    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            DownloadDiagnostics.shared.record(.response, stage: .interpreter,
                code: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw localSpeechError("Speech runtime download failed: HTTP \(status). Check the network or VPN and retry.", category: .http, code: status)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch { finish(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // URLSession serializes delegate callbacks on its delegate queue.
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastUpdate = now
        progress(LocalSpeechMessage(phase: "interpreter", downloaded: totalBytesWritten,
                                    total: max(0, totalBytesExpectedToWrite),
                                    speed: Double(totalBytesWritten) / max(0.001, now.timeIntervalSince(started))))
    }
}
