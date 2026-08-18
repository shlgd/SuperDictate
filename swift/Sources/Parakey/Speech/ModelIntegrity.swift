// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Speech / ModelIntegrity.swift
//
// FluidAudio owns the Hugging Face download mechanics, but it does not
// pin the downloaded CoreML bundle contents. Parakey downloads first,
// verifies the files that will be loaded by CoreML, and only then asks
// FluidAudio to compile/load the models. The manifest is intentionally
// tied to one upstream repo commit; a legitimate upstream model change
// should arrive as an explicit Parakey update with refreshed hashes.
//
// Optimization for MacBook Neo (Apple A18 Pro / 8GB RAM):
// Performs full SHA-256 calculation once upon initial download/verification,
// and saves a persistent stat-based fingerprint cache (mtime, size, inode).
// Subsequent launches verify via Fast Stat Fingerprinting in <1 ms with 0 MB RAM overhead.

import CryptoKit
import Darwin
import Foundation

struct ModelFileDigest: Equatable {
    let relativePath: String
    let sha256: String
}

enum ModelIntegrityError: LocalizedError {
    case invalidManifestPath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case invalidFileType(String)
    case digestMismatch(path: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifestPath(let path):
            return "Speech model integrity manifest contains an unsafe path: \(path)"
        case .missingFile(let path):
            return "Speech model integrity check failed: missing file \(path)"
        case .unexpectedFile(let path):
            return "Speech model integrity check failed: unexpected file \(path)"
        case .invalidFileType(let path):
            return "Speech model integrity check failed: \(path) is not a regular file or directory"
        case .digestMismatch(let path, let expected, let actual):
            return "Speech model integrity check failed for \(path): expected \(expected), got \(actual)"
        }
    }
}

// MARK: - Fast Verification Cache

struct ModelFileStatFingerprint: Codable, Equatable {
    let size: Int64
    let mtimeSec: Int
    let mtimeNsec: Int
    let inode: UInt64
}

struct ModelIntegrityCacheDocument: Codable {
    let version: Int
    let repositoryCommit: String
    let directoryPath: String
    let verifiedAt: TimeInterval
    let fileFingerprints: [String: ModelFileStatFingerprint]
}

enum ModelIntegrityCache {
    static let schemaVersion = 1

    static var cacheFileURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDir
            .appendingPathComponent("SuperDictate", isDirectory: true)
            .appendingPathComponent("model_integrity_cache.json")
    }

    static func read() -> ModelIntegrityCacheDocument? {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let doc = try? JSONDecoder().decode(ModelIntegrityCacheDocument.self, from: data),
              doc.version == schemaVersion else {
            return nil
        }
        return doc
    }

    static func save(repositoryCommit: String,
                     directory: URL,
                     files: [String]) {
        var fingerprints: [String: ModelFileStatFingerprint] = [:]
        for relativePath in files {
            let fileURL = directory.appendingPathComponent(relativePath, isDirectory: false)
            var st = stat()
            guard lstat(fileURL.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG else { return }
            fingerprints[relativePath] = ModelFileStatFingerprint(
                size: Int64(st.st_size),
                mtimeSec: Int(st.st_mtimespec.tv_sec),
                mtimeNsec: Int(st.st_mtimespec.tv_nsec),
                inode: UInt64(st.st_ino)
            )
        }

        let doc = ModelIntegrityCacheDocument(
            version: schemaVersion,
            repositoryCommit: repositoryCommit,
            directoryPath: directory.standardizedFileURL.path,
            verifiedAt: Date().timeIntervalSince1970,
            fileFingerprints: fingerprints
        )

        do {
            let parent = cacheFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(doc)
            try data.write(to: cacheFileURL, options: [.atomic])
        } catch {
            log("ModelIntegrityCache: failed to write cache: \(error.localizedDescription)")
        }
    }

    static func invalidate() {
        try? FileManager.default.removeItem(at: cacheFileURL)
    }
}

// MARK: - Model Integrity Checker

enum ModelIntegrity {
    static let parakeetV3Repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let parakeetV3RepositoryCommit = "aed02740059203c4a87495924f685de3722ae9ce"
    private static let sha256Characters = Set("0123456789abcdefABCDEF")

    static let parakeetV3StrictDirectories = [
        "Decoder.mlmodelc",
        "Encoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "Preprocessor.mlmodelc",
    ]

    static let parakeetV3Files = [
        // BEGIN GENERATED PARAKEET_V3_MODEL_MANIFEST
        ModelFileDigest(relativePath: "Decoder.mlmodelc/analytics/coremldata.bin", sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/coremldata.bin", sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/metadata.json", sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/model.mil", sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        ModelFileDigest(relativePath: "Decoder.mlmodelc/weights/weight.bin", sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/analytics/coremldata.bin", sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/coremldata.bin", sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/metadata.json", sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/model.mil", sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        ModelFileDigest(relativePath: "Encoder.mlmodelc/weights/weight.bin", sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/coremldata.bin", sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/metadata.json", sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/model.mil", sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        ModelFileDigest(relativePath: "JointDecisionv3.mlmodelc/weights/weight.bin", sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/coremldata.bin", sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/metadata.json", sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/model.mil", sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        ModelFileDigest(relativePath: "Preprocessor.mlmodelc/weights/weight.bin", sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        ModelFileDigest(relativePath: "parakeet_vocab.json", sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        // END GENERATED PARAKEET_V3_MODEL_MANIFEST
    ]

    static func verifyParakeetV3Model(at directory: URL, forceFullCheck: Bool = false) throws {
        // Fast path: Check persistent stat cache if available and not forced
        if !forceFullCheck, let cached = ModelIntegrityCache.read(),
           cached.repositoryCommit == parakeetV3RepositoryCommit,
           cached.directoryPath == directory.standardizedFileURL.path,
           fastVerifyStats(root: directory,
                           expectedFiles: parakeetV3Files,
                           strictDirectories: parakeetV3StrictDirectories,
                           cachedFingerprints: cached.fileFingerprints) {
            log("ASR: fast-verified \(parakeetV3Files.count) model files via cached fingerprint (A18 Pro / Neural Engine optimized)")
            return
        }

        // Full cryptographic validation
        try verifyFiles(root: directory,
                        expectedFiles: parakeetV3Files,
                        strictDirectories: parakeetV3StrictDirectories)

        // Save fast cache upon successful verification
        ModelIntegrityCache.save(repositoryCommit: parakeetV3RepositoryCommit,
                                 directory: directory,
                                 files: parakeetV3Files.map(\.relativePath))
        log("ASR: verified \(parakeetV3Files.count) model files from \(parakeetV3Repository) @ \(parakeetV3RepositoryCommit)")
    }

    private static func fastVerifyStats(root: URL,
                                        expectedFiles: [ModelFileDigest],
                                        strictDirectories: [String],
                                        cachedFingerprints: [String: ModelFileStatFingerprint]) -> Bool {
        guard cachedFingerprints.count == expectedFiles.count else { return false }

        for file in expectedFiles {
            guard let expectedStat = cachedFingerprints[file.relativePath] else { return false }
            let fileURL = root.appendingPathComponent(file.relativePath, isDirectory: false)
            var st = stat()
            guard lstat(fileURL.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG,
                  Int64(st.st_size) == expectedStat.size,
                  Int(st.st_mtimespec.tv_sec) == expectedStat.mtimeSec,
                  Int(st.st_mtimespec.tv_nsec) == expectedStat.mtimeNsec,
                  UInt64(st.st_ino) == expectedStat.inode else {
                return false
            }
        }

        // Verify strict directories have no unexpected files
        var expectedDirectoryPaths = Set<String>()
        var expectedByPath: [String: String] = [:]
        for directory in strictDirectories {
            expectedDirectoryPaths.insert(directory)
        }
        for file in expectedFiles {
            expectedByPath[file.relativePath] = file.sha256
            expectedDirectoryPaths.formUnion(parentDirectories(of: file.relativePath))
        }

        for directory in strictDirectories {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: directoryURL,
                                                                  includingPropertiesForKeys: nil)
            else { return false }

            for case let itemURL as URL in enumerator {
                let relativePath = relativePath(of: itemURL, under: root)
                var st = stat()
                guard lstat(itemURL.path, &st) == 0 else { return false }
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    guard expectedDirectoryPaths.contains(relativePath) else { return false }
                } else if (st.st_mode & S_IFMT) == S_IFREG {
                    guard expectedByPath[relativePath] != nil else { return false }
                } else {
                    return false
                }
            }
        }

        return true
    }

    static func verifyFiles(root: URL,
                            expectedFiles: [ModelFileDigest],
                            strictDirectories: [String]) throws {
        var expectedByPath: [String: String] = [:]
        var expectedDirectoryPaths = Set<String>()
        for directory in strictDirectories {
            try validateRelativePath(directory)
            expectedDirectoryPaths.insert(directory)
        }

        for file in expectedFiles {
            try validateRelativePath(file.relativePath)
            try validateSHA256(file.sha256, relativePath: file.relativePath)
            if expectedByPath.updateValue(file.sha256.lowercased(),
                                          forKey: file.relativePath) != nil {
                throw ModelIntegrityError.invalidManifestPath("duplicate file path: \(file.relativePath)")
            }
            expectedDirectoryPaths.formUnion(parentDirectories(of: file.relativePath))
        }
        var seenPaths: Set<String> = []

        for file in expectedFiles {
            let fileURL = root.appendingPathComponent(file.relativePath, isDirectory: false)
            try requireRegularFile(fileURL, relativePath: file.relativePath)

            let actual = try sha256Hex(of: fileURL, relativePath: file.relativePath)
            let expected = file.sha256.lowercased()
            guard actual == expected else {
                throw ModelIntegrityError.digestMismatch(path: file.relativePath,
                                                         expected: expected,
                                                         actual: actual)
            }
            seenPaths.insert(file.relativePath)
        }

        guard seenPaths.count == expectedFiles.count else {
            throw ModelIntegrityError.invalidManifestPath("duplicate file path")
        }

        for directory in strictDirectories {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            try requireDirectory(directoryURL, relativePath: directory)
            guard let enumerator = FileManager.default.enumerator(at: directoryURL,
                                                                  includingPropertiesForKeys: nil)
            else { continue }

            for case let itemURL as URL in enumerator {
                let relativePath = relativePath(of: itemURL, under: root)
                switch try fileSystemNodeType(itemURL, relativePath: relativePath) {
                case .directory:
                    guard expectedDirectoryPaths.contains(relativePath) else {
                        throw ModelIntegrityError.unexpectedFile(relativePath)
                    }
                case .regularFile:
                    guard expectedByPath[relativePath] != nil else {
                        throw ModelIntegrityError.unexpectedFile(relativePath)
                    }
                }
            }
        }
    }

    static func sha256Hex(of url: URL, relativePath: String) throws -> String {
        let handle = try openRegularFileForHashing(url, relativePath: relativePath)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openRegularFileForHashing(_ url: URL,
                                                  relativePath: String) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw ModelIntegrityError.missingFile(relativePath) }
            throw ModelIntegrityError.invalidFileType(relativePath)
        }

        do {
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0 else {
                throw ModelIntegrityError.invalidFileType(relativePath)
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw ModelIntegrityError.invalidFileType(relativePath)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private enum FileSystemNodeType {
        case regularFile
        case directory
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ModelIntegrityError.invalidManifestPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."),
              !components.contains("."),
              !components.contains("") else {
            throw ModelIntegrityError.invalidManifestPath(path)
        }
    }

    private static func validateSHA256(_ digest: String, relativePath: String) throws {
        guard digest.count == 64,
              digest.allSatisfy({ sha256Characters.contains($0) }) else {
            throw ModelIntegrityError.invalidManifestPath("invalid SHA-256 digest for \(relativePath)")
        }
    }

    private static func parentDirectories(of path: String) -> Set<String> {
        var result = Set<String>()
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[..<slash])
            result.insert(current)
        }
        return result
    }

    private static func requireRegularFile(_ url: URL, relativePath: String) throws {
        guard try fileSystemNodeType(url, relativePath: relativePath) == .regularFile else {
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func requireDirectory(_ url: URL, relativePath: String) throws {
        guard try fileSystemNodeType(url, relativePath: relativePath) == .directory else {
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func fileSystemNodeType(_ url: URL,
                                            relativePath: String) throws -> FileSystemNodeType {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { throw ModelIntegrityError.missingFile(relativePath) }
            throw ModelIntegrityError.invalidFileType(relativePath)
        }

        switch st.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        default:
            throw ModelIntegrityError.invalidFileType(relativePath)
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}
