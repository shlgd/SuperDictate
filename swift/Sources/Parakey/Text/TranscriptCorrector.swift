// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Text / TranscriptCorrector.swift

import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct TranscriptCorrection: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
}

struct TranscriptCorrectionsDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let corrections: [TranscriptCorrection]
}

enum TranscriptCorrectionsDocumentError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This corrections file uses schema version \(version), which this version of Parakey cannot read."
        }
    }
}

enum TranscriptCorrectionsTransferError: LocalizedError {
    case fileTooLarge(Int, Int)
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            let actual = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "This corrections file is \(actual), which is larger than Parakey's \(maximum) import limit."
        case .notRegularFile:
            return "The selected corrections path is not a regular file."
        }
    }
}

enum TranscriptCorrectionsTransfer {
    static let schemaVersion = 1
    static let maxFileBytes = 4 * 1024 * 1024

    static var contentType: UTType {
        UTType(filenameExtension: CORRECTIONS_FILE_EXTENSION)
            ?? UTType(exportedAs: CORRECTIONS_FILE_UTI, conformingTo: .json)
    }

    static func encode(_ corrections: [TranscriptCorrection]) throws -> Data {
        let document = TranscriptCorrectionsDocument(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: normalizedTranscriptCorrections(corrections)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    struct CountedDecodeResult: Sendable, Equatable {
        let corrections: [TranscriptCorrection]
        let originalCount: Int
    }

    static func decode(_ data: Data) throws -> [TranscriptCorrection] {
        try decodeCounted(data).corrections
    }

    static func decodeCounted(_ data: Data) throws -> CountedDecodeResult {
        try validateTransferSize(data.count)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let document = try? decoder.decode(TranscriptCorrectionsDocument.self, from: data) {
            guard document.schemaVersion == schemaVersion else {
                throw TranscriptCorrectionsDocumentError.unsupportedSchema(document.schemaVersion)
            }
            return CountedDecodeResult(
                corrections: normalizedTranscriptCorrections(document.corrections),
                originalCount: document.corrections.count
            )
        }

        let legacy = try decoder.decode([TranscriptCorrection].self, from: data)
        return CountedDecodeResult(
            corrections: normalizedTranscriptCorrections(legacy),
            originalCount: legacy.count
        )
    }

    static func validateTransferSize(_ bytes: Int) throws {
        guard bytes <= maxFileBytes else {
            throw TranscriptCorrectionsTransferError.fileTooLarge(bytes, maxFileBytes)
        }
    }

    @discardableResult
    static func write(_ corrections: [TranscriptCorrection], to url: URL) throws -> Data {
        let data = try encode(corrections)
        try validateTransferSize(data.count)
        try validateWritablePath(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }

    static func read(from url: URL) throws -> [TranscriptCorrection] {
        try decode(try readData(from: url))
    }

    static func readCounted(from url: URL) throws -> CountedDecodeResult {
        try decodeCounted(try readData(from: url))
    }

    private static func readData(from url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw TranscriptCorrectionsTransferError.notRegularFile
            }
            throw currentPOSIXError()
        }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw currentPOSIXError()
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TranscriptCorrectionsTransferError.notRegularFile
        }
        if st.st_size > off_t(maxFileBytes) {
            throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size), maxFileBytes)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while true {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            try validateTransferSize(data.count)
        }
        return data
    }

    private static func validateWritablePath(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw currentPOSIXError()
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TranscriptCorrectionsTransferError.notRegularFile
        }
    }
}

enum TranscriptCorrectionsSyncPathError: LocalizedError {
    case isSymbolicLink

    var errorDescription: String? {
        switch self {
        case .isSymbolicLink:
            return "The text correction sync file is a symbolic link. Parakey refuses to sync through symlinks. Reconnect Parakey to a regular file."
        }
    }
}

func normalizedCorrectionSyncFilePath(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= MAX_CORRECTION_SYNC_PATH_BYTES,
          !trimmed.unicodeScalars.contains(where: { $0.value == 0 }),
          (trimmed as NSString).isAbsolutePath else {
        return nil
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
}

func validateCorrectionSyncPath(_ url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return }
    if (st.st_mode & S_IFMT) == S_IFLNK {
        throw TranscriptCorrectionsSyncPathError.isSymbolicLink
    }
}

func shouldStopCorrectionSync(afterPathValidationError error: Error) -> Bool {
    error is TranscriptCorrectionsSyncPathError
}

func normalizedTranscriptCorrectionSource(_ source: String) -> String {
    source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

func normalizedTranscriptCorrections(_ corrections: [TranscriptCorrection]) -> [TranscriptCorrection] {
    var result: [TranscriptCorrection] = []
    var indexBySource: [String: Int] = [:]

    for correction in corrections {
        let source = correction.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedTranscriptCorrectionSource(source)
        guard !source.isEmpty,
              !replacement.isEmpty,
              !key.isEmpty,
              source.utf8.count <= MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
              replacement.utf8.count <= MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES,
              !source.unicodeScalars.contains(where: { $0.value == 0 }),
              !replacement.unicodeScalars.contains(where: { $0.value == 0 }) else {
            continue
        }

        let cleaned = TranscriptCorrection(source: source, replacement: replacement)
        if let existing = indexBySource[key] {
            result[existing] = cleaned
        } else {
            guard result.count < MAX_TRANSCRIPT_CORRECTIONS else { continue }
            indexBySource[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}

func correctionImportCountText(sourceName: String, originalCount: Int, keptCount: Int) -> String {
    guard originalCount > keptCount else {
        return "\(sourceName) contains \(keptCount) corrections."
    }
    return "\(sourceName) contains \(originalCount) entries; only the first \(keptCount) valid corrections (Parakey keeps at most \(MAX_TRANSCRIPT_CORRECTIONS)) will be imported."
}

func correctionImportMergeCapWarningText(existingCount: Int,
                                         newCount: Int,
                                         cap: Int = MAX_TRANSCRIPT_CORRECTIONS) -> String? {
    let mergedCount = existingCount + newCount
    guard mergedCount > cap else { return nil }
    return "Merging would produce \(mergedCount) corrections; Parakey keeps at most \(cap), so \(mergedCount - cap) would be dropped."
}

private func utf8ClippedPrefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var result = ""
    var usedBytes = 0
    for character in text {
        let byteCount = String(character).utf8.count
        guard usedBytes + byteCount <= maxBytes else { break }
        result.append(character)
        usedBytes += byteCount
    }
    return result
}

func correctionSourcePrefill(from transcript: String) -> String {
    let flat = transcript
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return utf8ClippedPrefix(flat, maxBytes: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)
}

struct TranscriptCorrectionSyncMergeResult: Equatable {
    let corrections: [TranscriptCorrection]
    let conflictingSources: [String]
}

struct CorrectionSyncFileFingerprint: Equatable {
    let modifiedAt: Date?
    let size: Int?
    let sha256: String
}

func correctionSyncFingerprint(for url: URL) -> CorrectionSyncFileFingerprint? {
    do {
        let digest = try correctionSyncFileSHA256Hex(url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CorrectionSyncFileFingerprint(modifiedAt: values.contentModificationDate,
                                             size: values.fileSize,
                                             sha256: digest)
    } catch {
        return nil
    }
}

func correctionSyncFingerprint(forWrittenData data: Data, at url: URL) -> CorrectionSyncFileFingerprint {
    var hasher = SHA256()
    hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    return CorrectionSyncFileFingerprint(modifiedAt: modifiedAt,
                                         size: data.count,
                                         sha256: digest)
}

private func correctionSyncFileSHA256Hex(_ url: URL) throws -> String {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw TranscriptCorrectionsTransferError.notRegularFile
    }
    guard st.st_size <= TranscriptCorrectionsTransfer.maxFileBytes else {
        throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size),
                                                              TranscriptCorrectionsTransfer.maxFileBytes)
    }

    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
            break
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func mergedTranscriptCorrectionsForSync(base: [TranscriptCorrection],
                                        local: [TranscriptCorrection],
                                        remote: [TranscriptCorrection]) -> TranscriptCorrectionSyncMergeResult {
    let base = normalizedTranscriptCorrections(base)
    let local = normalizedTranscriptCorrections(local)
    let remote = normalizedTranscriptCorrections(remote)

    func dictionaryBySource(_ corrections: [TranscriptCorrection]) -> [String: TranscriptCorrection] {
        Dictionary(uniqueKeysWithValues: corrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })
    }

    let baseBySource = dictionaryBySource(base)
    let localBySource = dictionaryBySource(local)
    let remoteBySource = dictionaryBySource(remote)

    var orderedSources: [String] = []
    var seenSources: Set<String> = []
    func appendSources(from corrections: [TranscriptCorrection]) {
        for correction in corrections {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            if seenSources.insert(key).inserted {
                orderedSources.append(key)
            }
        }
    }

    appendSources(from: local)
    appendSources(from: remote)
    appendSources(from: base)

    var merged: [TranscriptCorrection] = []
    var conflicts: [String] = []

    for source in orderedSources {
        let baseline = baseBySource[source]
        let localCorrection = localBySource[source]
        let remoteCorrection = remoteBySource[source]

        let chosen: TranscriptCorrection?
        if localCorrection == remoteCorrection {
            chosen = localCorrection
        } else if localCorrection == baseline {
            chosen = remoteCorrection
        } else if remoteCorrection == baseline {
            chosen = localCorrection
        } else {
            conflicts.append(localCorrection?.source ?? remoteCorrection?.source ?? baseline?.source ?? source)
            continue
        }

        if let chosen {
            merged.append(chosen)
        }
    }

    return TranscriptCorrectionSyncMergeResult(corrections: merged,
                                               conflictingSources: conflicts)
}

enum TranscriptCorrector {
    private struct Match {
        let range: NSRange
        let replacement: String
    }

    static func apply(to text: String, corrections: [TranscriptCorrection]) -> (text: String, appliedCount: Int) {
        let active = normalizedTranscriptCorrections(corrections)
            .sorted { lhs, rhs in
                if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
                return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
            }

        guard !text.isEmpty, !active.isEmpty else { return (text, 0) }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []

        for correction in active {
            guard let pattern = pattern(for: correction.source),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                guard !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                matches.append(Match(range: range, replacement: correction.replacement))
            }
        }

        guard !matches.isEmpty else { return (text, 0) }

        let rewritten = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: match.range, with: match.replacement)
        }
        return (rewritten as String, matches.count)
    }

    private static func pattern(for source: String) -> String? {
        let parts = source
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return #"(?<![\p{L}\p{N}_])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
    }
}
