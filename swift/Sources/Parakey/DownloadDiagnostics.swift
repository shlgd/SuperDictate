import Foundation
import Darwin

enum DownloadStage: String, Codable, Sendable {
    case unknown, storage, interpreter, runtime, listing, downloading, verifying, ready, cancelled, cancelling
    case interpreterPrepare = "interpreter-prepare"
    case runtimeVerifying = "runtime-verifying"
    case runtimeEnvironment = "runtime-environment"
    case runtimePackages = "runtime-packages"
    case runtimeImports = "runtime-imports"
    case installerLaunch = "installer-launch"
    case runtimeRepair = "runtime-repair"
}

enum DownloadFailure: String, Codable, Sendable {
    case unknown, network, timeout, tls, http, filesystem, checksum, cancelled
    case dependencies, imports, process, protocolError = "protocol", diskSpace = "disk-space"

    static func classify(_ error: Error) -> Self {
        let error = error as NSError
        if let value = error.userInfo["downloadFailure"] as? String,
           let category = Self(rawValue: value) { return category }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) {
            return .diskSpace
        }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorCancelled: return .cancelled
            case -1206 ... -1200: return .tls
            default: return .network
            }
        }
        if error.domain == NSPOSIXErrorDomain || error.domain == NSCocoaErrorDomain { return .filesystem }
        return .unknown
    }
}

struct DownloadDiagnosticRecord: Codable, Sendable {
    enum Event: String, Codable, Sendable {
        case click, start, duplicate, stage, progress, ui, cancel, cancelled, completed, failed, retry, response, export
    }
    enum Model: String, Codable, Sendable {
        case whisper_large_v3, whisper_turbo, qwen_06, qwen_17, gigaam_v3
    }
    let event: Event
    var model: Model?
    var stage: DownloadStage?
    var elapsedSeconds: Int?
    var bytes: Int64?
    var totalBytes: Int64?
    var failure: DownloadFailure?
    var code: Int?
    var progressVisible: Bool?
    var buttonEnabled: Bool?
}

// No arbitrary strings, paths, error descriptions, transcripts or raw logs enter
// this store. Export decodes and re-encodes the allowlisted schema again.
final class DownloadDiagnostics: @unchecked Sendable {
    static let shared = DownloadDiagnostics(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SuperDictate/DownloadDiagnostics.json"),
        persist: !CommandLine.arguments.contains("--self-test"))
    private let queue = DispatchQueue(label: "com.local.superdictate.download-diagnostics", qos: .utility)
    private let url: URL
    private var records: [DownloadDiagnosticRecord]
    private var writeFailed = false
    private let persist: Bool
    private static let limit = 400

    init(url: URL, persist: Bool = true) {
        self.url = url
        self.persist = persist
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if persist, size <= 512_000, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DownloadDiagnosticRecord].self, from: data) {
            records = Array(decoded.suffix(Self.limit))
        } else { records = [] }
    }

    func record(_ event: DownloadDiagnosticRecord.Event, model: SpeechModelProfile? = nil,
                stage: DownloadStage? = nil, elapsed: Int? = nil, bytes: Int64? = nil,
                total: Int64? = nil, failure: DownloadFailure? = nil, code: Int? = nil,
                visible: Bool? = nil, enabled: Bool? = nil) {
        let record = DownloadDiagnosticRecord(event: event,
            model: model.flatMap { DownloadDiagnosticRecord.Model(rawValue: $0.rawValue) },
            stage: stage, elapsedSeconds: elapsed.map { max(0, $0) },
            bytes: bytes.map { max(0, $0) }, totalBytes: total.map { max(0, $0) },
            failure: failure, code: code, progressVisible: visible, buttonEnabled: enabled)
        queue.async { [self] in
            records.append(record)
            if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
            guard persist else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(records).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                writeFailed = false
            } catch { writeFailed = true }
        }
    }

    struct Report: Codable {
        let schema: Int
        let privacy: String
        let appVersion: String
        let appBuild: String
        let macOS: String
        let architecture: String
        let isolatedPython: Bool
        let persistenceFailed: Bool
        let events: [DownloadDiagnosticRecord]
    }

    func reportData(version: String, build: String) throws -> Data {
        try queue.sync {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "other"
            #endif
            return try encoder.encode(Report(schema: 1,
                privacy: "Technical download events only. No audio, transcripts, clipboard, usernames, paths, URLs, tokens, device identifiers or raw logs. Created locally; not uploaded automatically.",
                appVersion: Self.safeVersion(version), appBuild: Self.safeVersion(build),
                macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                architecture: architecture, isolatedPython: true, persistenceFailed: writeFailed, events: records))
        }
    }

    private static func safeVersion(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return "unknown" }
        return value
    }

    func export(to directory: URL, version: String, build: String) throws -> URL {
        let data = try reportData(version: version, build: build)
        let destination = directory.appendingPathComponent("SuperDictate-anonymous-\(UUID().uuidString.prefix(8)).json")
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }
}

enum LocalSpeechEnvironment {
    static func make(temporaryDirectory: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "LANG": "en_US.UTF-8", "TMPDIR": temporaryDirectory.path,
         "TOKENIZERS_PARALLELISM": "false", "PYTHONUNBUFFERED": "1",
         "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
         "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
         "HF_HOME": temporaryDirectory.appendingPathComponent("huggingface").path,
         "XDG_CACHE_HOME": temporaryDirectory.appendingPathComponent("cache").path,
         "NUMBA_CACHE_DIR": temporaryDirectory.appendingPathComponent("numba").path,
         "PIP_CONFIG_FILE": "/dev/null", "PIP_NO_CACHE_DIR": "1", "PIP_NO_INPUT": "1"]
    }
}

#if DEBUG
extension DownloadDiagnostics {
    static func testPrivacy() throws {
        guard DownloadFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskSpace,
              DownloadFailure.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .diskSpace else {
            throw localSpeechError("Disk-full errors must have an actionable category")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("events.json")
        let store = DownloadDiagnostics(url: source)
        let secret = "SECRET_TRANSCRIPT /Users/private/name https://private.example/?token=hf_secret"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret])
        store.record(.failed, model: .whisperTurbo, stage: .runtimePackages,
                     failure: DownloadFailure.classify(error), code: error.code)
        let file = try store.export(to: root, version: secret, build: secret)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["SECRET_TRANSCRIPT", "/Users/", "private.example", "hf_secret"] {
            guard !text.contains(forbidden) else { throw localSpeechError("Diagnostic export leaked a sentinel") }
        }
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.appVersion == "unknown", report.events.first?.failure == .timeout,
              let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber,
              permissions.intValue == 0o600 else { throw localSpeechError("Unsafe export metadata or permissions") }
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [[String: Any]]
        raw[0]["transcript"] = secret
        try JSONSerialization.data(withJSONObject: raw).write(to: source)
        let reloaded = DownloadDiagnostics(url: source)
        let clean = try reloaded.reportData(version: "0.2.47", build: "48")
        guard !String(decoding: clean, as: UTF8.self).contains("SECRET_TRANSCRIPT") else {
            throw localSpeechError("Export copied unknown persisted fields")
        }
        for _ in 0..<405 { reloaded.record(.progress, stage: .downloading, bytes: 1, total: 2) }
        let bounded = try JSONDecoder().decode(Report.self, from: reloaded.reportData(version: "1", build: "1"))
        guard bounded.events.count == 400 else { throw localSpeechError("Diagnostic history is not bounded") }
        let environment = LocalSpeechEnvironment.make(temporaryDirectory: root)
        guard environment["PIP_CONFIG_FILE"] == "/dev/null", environment["PIP_INDEX_URL"] == nil,
              environment["PYTHONHOME"] == nil, environment["PYTHONPATH"] == nil,
              environment["HF_TOKEN"] == nil, environment["HF_ENDPOINT"] == nil,
              environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin" else {
            throw localSpeechError("Runtime inherited user configuration")
        }
        print("PASS anonymous export schema, sensitive sentinels, reload, permissions, retention, environment")
    }
}
#endif
