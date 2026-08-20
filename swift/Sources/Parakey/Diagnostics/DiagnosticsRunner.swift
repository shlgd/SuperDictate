// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Diagnostics / DiagnosticsRunner.swift

import AppKit
import Foundation

struct DiagnosticsReportSnapshot {
    let generated: String
    let appVersion: String
    let appBuild: String
    let macOS: String
    let bundleID: String
    let bundlePath: String
    let installKind: String
    let status: String
    let startup: String
    let speechModelReady: Bool
    let coreRuntimeReady: Bool
    let readyForDictation: Bool
    let recordingActive: Bool
    let transcribing: Bool
    let memoryLines: [String]
    let permissionLines: [String]
    let settingLines: [String]
    let updateLines: [String]
    let microphoneLines: [String]
    let logPath: String
    let recentLogLines: [String]
}

private func diagnosticBulletLines(_ lines: [String], emptyText: String) -> String {
    guard !lines.isEmpty else { return "- \(emptyText)" }
    return lines.map { "- \($0)" }.joined(separator: "\n")
}

func diagnosticsReportText(from snapshot: DiagnosticsReportSnapshot) -> String {
    """
    Parakey diagnostics
    Generated: \(snapshot.generated)
    App version: \(snapshot.appVersion) (\(snapshot.appBuild))
    macOS: \(snapshot.macOS)
    Bundle ID: \(snapshot.bundleID)
    Bundle path: \(snapshot.bundlePath)
    Install kind: \(snapshot.installKind)

    Status:
    - Menu: \(snapshot.status)
    - Startup: \(snapshot.startup)
    - Speech model ready: \(snapshot.speechModelReady)
    - Core runtime ready: \(snapshot.coreRuntimeReady)
    - Ready for dictation: \(snapshot.readyForDictation)
    - Recording active: \(snapshot.recordingActive)
    - Transcribing: \(snapshot.transcribing)

    Memory:
    \(diagnosticBulletLines(snapshot.memoryLines, emptyText: "Unavailable"))

    Permissions:
    \(diagnosticBulletLines(snapshot.permissionLines, emptyText: "Unavailable"))

    Settings:
    \(diagnosticBulletLines(snapshot.settingLines, emptyText: "Unavailable"))

    Update:
    \(diagnosticBulletLines(snapshot.updateLines, emptyText: "Unavailable"))

    Microphone:
    \(diagnosticBulletLines(snapshot.microphoneLines, emptyText: "Unavailable"))

    Recent log lines:
    \(diagnosticBulletLines(snapshot.recentLogLines, emptyText: "No recent log lines available"))

    Logs: \(snapshot.logPath)
    Privacy: transcript text and text-correction contents are not included.
    """
}

func recentDiagnosticLogLines(from url: URL = Logger.shared.fileURL,
                              maxBytes: Int = DIAGNOSTICS_LOG_MAX_BYTES,
                              maxLines: Int = DIAGNOSTICS_LOG_MAX_LINES) throws -> [String] {
    guard maxBytes > 0, maxLines > 0 else { return [] }

    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        if errno == ENOENT { return [] }
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
    guard st.st_size > 0 else { return [] }

    let startOffset = max(Int64(0), Int64(st.st_size) - Int64(maxBytes))
    guard Darwin.lseek(fd, off_t(startOffset), SEEK_SET) >= 0 else {
        throw currentPOSIXError()
    }

    var data = Data()
    data.reserveCapacity(min(maxBytes, Int(st.st_size)))
    while data.count < maxBytes {
        let remaining = maxBytes - data.count
        var buffer = [UInt8](repeating: 0, count: min(8192, remaining))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
        guard bytesRead > 0 else { break }
        data.append(buffer, count: bytesRead)
    }

    var text = String(decoding: data, as: UTF8.self)
    if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
    }

    let sanitized = text
        .components(separatedBy: .newlines)
        .map(sanitizedDiagnosticLogLine)
        .filter { !$0.isEmpty }
    return Array(sanitized.suffix(maxLines))
}

private func sanitizedDiagnosticLogLine(_ line: String) -> String {
    var result = String()
    result.reserveCapacity(min(line.count, DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS))
    for scalar in line.unicodeScalars {
        guard result.count < DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS else { break }
        if scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f) {
            result.unicodeScalars.append(scalar)
        } else {
            result.append(" ")
        }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

func parseSemver(_ s: String) -> [Int] {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .drop(while: { $0 == "v" || $0 == "V" })
    return trimmed.split(separator: ".").map { chunk in
        var n = 0
        var seen = false
        for c in chunk {
            guard let d = c.wholeNumberValue else { break }
            let multiplied = n.multipliedReportingOverflow(by: 10)
            if multiplied.overflow { return Int.max }
            let added = multiplied.partialValue.addingReportingOverflow(d)
            if added.overflow { return Int.max }
            n = added.partialValue
            seen = true
        }
        return seen ? n : 0
    }
}

func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = parseSemver(candidate)
    let b = parseSemver(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

func runAudioCaptureDiagnostic(arguments: [String]) -> Int32? {
    guard arguments.first == "--diagnose-audio-capture" else { return nil }
    guard arguments.count == 3,
          let duration = TimeInterval(arguments[2]),
          duration > 0,
          duration <= 15 else {
        fputs("usage: SuperDictate --diagnose-audio-capture <device-uid|default> <seconds>\n",
              stderr)
        return EXIT_FAILURE
    }

    let preference = arguments[1] == "default" ? "" : arguments[1]
    let capture = AudioCapture()
    do {
        try capture.startRecording(inputDevicePreference: preference)
        Thread.sleep(forTimeInterval: duration)
        let recording = capture.endRecording()
        capture.stopEngine()

        let capturedSeconds = Double(recording.samples.count) / SAMPLE_RATE
        let peak = recording.samples.reduce(Float(0)) { max($0, abs($1)) }
        print(
            String(
                format: "AUDIO CAPTURE: requested=%.2fs captured=%.3fs samples=%d peak=%.6f",
                duration,
                capturedSeconds,
                recording.samples.count,
                peak
            )
        )
        return capturedSeconds >= duration * 0.75 ? EXIT_SUCCESS : EXIT_FAILURE
    } catch {
        capture.stopEngine()
        fputs("AUDIO CAPTURE FAILED: \(error.localizedDescription)\n", stderr)
        return EXIT_FAILURE
    }
}
