// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Core / Logger.swift

import Foundation

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/SuperDictate.log.

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let url: URL
    private let q = DispatchQueue(label: "ParakeyLogger")

    var fileURL: URL { url }

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        url = logs.appendingPathComponent("SuperDictate.log")
    }

    func log(_ msg: String) {
        let stamp = ISO8601DateFormatter.timeOnly.string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        q.async { [url] in
            do {
                try appendPrivateLogData(data, to: url)
            } catch {
                let fallback = "Logger: file write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
            }
        }
    }
}

func log(_ msg: String) {
    Logger.shared.log(msg)
}

func privacySafeLogPath(_ path: String) -> String {
    privacySafeLogPath(URL(fileURLWithPath: path))
}

func privacySafeLogPath(_ url: URL) -> String {
    let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name == "/" ? "<local path>" : name
}

func privacySafeBundlePath(_ path: String) -> String {
    switch path {
    case "/Applications/SuperDictate.app", "/tmp/SuperDictate-dev.app":
        return path
    default:
        return privacySafeLogPath(path)
    }
}

let PRIVATE_LOG_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)
let PRIVATE_HELPER_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)

func appendPrivateLogData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
        throw currentPOSIXError()
    }

    try writeAllData(data, to: fd)
}

func validateSingleLinkRegularFileDescriptor(_ fd: Int32) throws {
    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw posixError(EFTYPE)
    }
    guard st.st_nlink == 1 else {
        throw posixError(EMLINK)
    }
}

func writeAllData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd,
                                       base.advanced(by: offset),
                                       rawBuffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

extension ISO8601DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
