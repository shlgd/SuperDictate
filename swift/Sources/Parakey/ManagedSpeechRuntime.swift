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
            throw localSpeechError("At least 2 GB of free disk space is needed to prepare the speech runtime")
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
                throw localSpeechError("Speech runtime checksum mismatch")
            }
            let extract = Process()
            extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            extract.arguments = ["-xzf", archive.path, "-C", stage.path]
            extract.standardOutput = FileHandle.nullDevice
            extract.standardError = FileHandle.nullDevice
            try extract.run()
            extract.waitUntilExit()
            guard extract.terminationStatus == 0 else { throw localSpeechError("Could not unpack the speech runtime") }
        }.value
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

private final class RuntimeDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (LocalSpeechMessage) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private let started = Date()
    private var lastUpdate = Date.distantPast
    init(destination: URL, progress: @escaping @Sendable (LocalSpeechMessage) -> Void) {
        self.destination = destination
        self.progress = progress
    }
    func download(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 600
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
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw localSpeechError("Could not download the bundled speech runtime")
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
