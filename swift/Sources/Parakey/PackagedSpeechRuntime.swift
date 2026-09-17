import CryptoKit
import Darwin
import Foundation

enum PackagedSpeechRuntime {
    struct Manifest: Decodable, Sendable {
        let schema: Int
        let sha256: String
        let bytes: Int64
        let unpackedBytes: Int64
        let minimumMacOS: String
        let architecture: String
        let url: URL?
    }

    static var manifestURL: URL {
        if let url = Bundle.main.url(forResource: "speech-runtime", withExtension: "json") { return url }
        return LocalSpeechPaths.script.deletingLastPathComponent().appendingPathComponent("speech-runtime.json")
    }

    static func manifest(at url: URL = manifestURL) throws -> Manifest {
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard value.schema == 1, value.architecture == "arm64", value.bytes > 0,
              value.unpackedBytes > 0, value.sha256.count == 64,
              value.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw localSpeechError("Invalid packaged runtime manifest. Reinstall SuperDictate.", category: .checksum)
        }
        return value
    }

    static func directory(root: URL = LocalSpeechPaths.root, manifest: Manifest) -> URL {
        root.appendingPathComponent("packaged-\(manifest.sha256)")
    }

    static func python(root: URL = LocalSpeechPaths.root) -> URL? {
        guard let manifest = try? manifest() else { return nil }
        let directory = directory(root: root, manifest: manifest)
        let python = directory.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              (try? String(contentsOf: directory.appendingPathComponent(".verified"), encoding: .utf8)) == manifest.sha256 else { return nil }
        return python
    }

    static func ensure(progress: @escaping @Sendable (LocalSpeechMessage) -> Void) async throws -> URL {
        let specification = try manifest()
        let bundled = manifestURL.deletingLastPathComponent().appendingPathComponent("SuperDictate-SpeechRuntime.tar.gz")
        let source: URL
        if FileManager.default.fileExists(atPath: bundled.path) {
            source = bundled
        } else if let remote = specification.url, remote.scheme == "https", remote.host == "github.com",
                  remote.path.hasPrefix("/shlgd/SuperDictate/releases/download/") {
            source = remote
        } else { throw localSpeechError("The packaged speech runtime is missing. Reinstall SuperDictate.", category: .filesystem) }
        return try await ensure(archive: source, manifest: specification, progress: progress)
    }

    static func ensure(root: URL = LocalSpeechPaths.root, archive: URL,
                       manifest: Manifest,
                       progress: @escaping @Sendable (LocalSpeechMessage) -> Void) async throws -> URL {
        let fm = FileManager.default
        let destination = directory(root: root, manifest: manifest)
        let executable = destination.appendingPathComponent("bin/python3")
        func ready() -> Bool {
            fm.isExecutableFile(atPath: executable.path)
                && (try? String(contentsOf: destination.appendingPathComponent(".verified"), encoding: .utf8)) == manifest.sha256
        }
        if ready() { return executable }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.appendingPathComponent(".packaged-runtime.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw localSpeechError("Cannot access runtime storage", category: .filesystem) }
        defer { Darwin.close(descriptor) }
        let deadline = Date().addingTimeInterval(1800)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw localSpeechError("Cannot lock runtime storage", category: .filesystem) }
            if ready() { return executable }
            guard Date() < deadline else { throw localSpeechError("Timed out waiting for runtime installation", category: .timeout) }
            progress(LocalSpeechMessage(phase: "runtime-waiting"))
            try await Task.sleep(for: .seconds(1))
        }
        if ready() { return executable }
        try Task.checkCancellation()
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > manifest.unpackedBytes + (archive.isFileURL ? 0 : manifest.bytes) + 512_000_000 else {
            throw localSpeechError("Not enough free space for the packaged speech runtime", category: .diskSpace)
        }
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".packaged-stage-") { try fm.removeItem(at: entry) }
        let staging = root.appendingPathComponent(".packaged-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let source: URL
        if archive.isFileURL {
            source = archive
        } else {
            source = staging.appendingPathComponent("runtime.tar.gz")
            progress(LocalSpeechMessage(phase: "runtime-download", downloaded: 0, total: manifest.bytes))
            let transfer = RuntimeDownloadProgress(destination: source, resourceTimeout: 1800) { update in
                var update = update
                update.phase = "runtime-download"
                progress(update)
            }
            try await transfer.download(archive)
        }
        progress(LocalSpeechMessage(phase: "runtime-verifying"))
        try await Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            var hash = SHA256()
            var count: Int64 = 0
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                hash.update(data: data)
                count += Int64(data.count)
            }
            guard count == manifest.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else {
                throw localSpeechError("Packaged runtime checksum mismatch", category: .checksum)
            }
        }.value
        try Task.checkCancellation()
        progress(LocalSpeechMessage(phase: "runtime-unpacking"))
        try await RuntimeExtraction().run(executable: "/usr/bin/tar", arguments: ["-xzf", source.path, "-C", staging.path], timeout: 180)
        try Task.checkCancellation()
        let unpacked = staging.appendingPathComponent("runtime")
        guard fm.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/python3").path) else {
            throw localSpeechError("Incomplete packaged runtime", category: .checksum)
        }
        // Publish only a complete generation. Existing weights and runtimes remain intact.
        try manifest.sha256.write(to: unpacked.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: unpacked, to: destination)
        return executable
    }
}

#if DEBUG
extension PackagedSpeechRuntime {
    static func testArchive() async throws {
        let resources = LocalSpeechPaths.script.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/speech-runtime")
        let specification = try manifest(at: resources.appendingPathComponent("speech-runtime.json"))
        let archive = resources.appendingPathComponent("SuperDictate-SpeechRuntime.tar.gz")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("packaged-runtime-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldWeights = root.appendingPathComponent("models/existing/weights.bin")
        try FileManager.default.createDirectory(at: oldWeights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing model weights".utf8).write(to: oldWeights)
        let abandoned = root.appendingPathComponent(".packaged-stage-interrupted")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        let python = try await ensure(root: root, archive: archive, manifest: specification, progress: { _ in })
        guard try Data(contentsOf: oldWeights) == Data("existing model weights".utf8),
              !FileManager.default.fileExists(atPath: abandoned.path) else {
            throw localSpeechError("Runtime migration changed weights or left abandoned staging")
        }
        let missing = root.appendingPathComponent("missing-archive.tar.gz")
        let cached = try await ensure(root: root, archive: missing, manifest: specification, progress: { _ in
            assertionFailure("A ready generation must not be extracted or downloaded again")
        })
        guard python == cached else { throw localSpeechError("Packaged runtime cache is not stable") }
        try await RuntimeExtraction().run(executable: python.path, arguments: ["-I", "-B", "-c",
            "import ssl,mlx.core,mlx_whisper,mlx_audio.stt,gigaam; print('Packaged imports OK')"], timeout: 120)
        let brokenRoot = root.appendingPathComponent("broken")
        let brokenArchive = root.appendingPathComponent("broken.tar.gz")
        try Data("broken".utf8).write(to: brokenArchive)
        do {
            _ = try await ensure(root: brokenRoot, archive: brokenArchive, manifest: specification, progress: { _ in })
            throw localSpeechError("Corrupt packaged runtime was accepted")
        } catch {
            guard DownloadFailure.classify(error) == .checksum else { throw error }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: brokenRoot.path)
        guard files == [".packaged-runtime.lock"] else { throw localSpeechError("Corrupt runtime left staging files") }
        print("PASS packaged runtime: offline extraction, relocated imports, reuse without archive, existing weights preserved, interrupted staging recovered, corrupt archive cleanup")
    }
}
#endif
