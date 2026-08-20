// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Speech / SpeechModelProgress.swift

import Foundation
import FluidAudio

struct SpeechModelDownloadMetrics: Equatable, Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double?
    let estimatedSecondsRemaining: Double?
}

struct SpeechModelProgressUpdate: Sendable {
    let title: String
    let fraction: Double?
    let phase: String
    let metrics: SpeechModelDownloadMetrics?
    let didAdvance: Bool
    let shouldDispatch: Bool
}

func speechModelStartupStatusTitle(_ progress: DownloadUtils.DownloadProgress) -> String {
    switch progress.phase {
    case .listing:
        return "Checking speech model files…"
    case .downloading(let completedFiles, let totalFiles):
        guard totalFiles > 0 else { return "Loading cached speech model…" }
        let downloadFraction = min(max(progress.fractionCompleted / 0.5, 0), 1)
        let percent = min(100, max(0, Int((downloadFraction * 100).rounded())))
        return "Downloading speech model… \(percent)% (\(completedFiles)/\(totalFiles))"
    case .compiling:
        return "Preparing speech model…"
    }
}

func speechModelStartupProgressValue(_ progress: DownloadUtils.DownloadProgress) -> Double? {
    switch progress.phase {
    case .downloading(_, let totalFiles):
        guard totalFiles > 0 else { return nil }
        let raw = min(max(progress.fractionCompleted / 0.5, 0), 1)
        return (raw * 100).rounded() / 100.0   // round to 1%
    case .listing, .compiling:
        return nil
    }
}

func speechModelStartupPhaseName(_ progress: DownloadUtils.DownloadProgress) -> String {
    switch progress.phase {
    case .listing:
        return "listing"
    case .downloading:
        return "downloading"
    case .compiling:
        return "preparing"
    }
}

/// Thread-safe progress sampler. FluidAudio calls its handler on an
/// unspecified queue and may report many chunks per rendered frame.
final class SpeechModelProgressTracker: @unchecked Sendable {
    private var lastTitle: String = ""
    private var lastFraction: Double? = nil
    private var lastPhase: String?
    private var lastDownloadedBytes: Int64?
    private var sampleBytes: Int64?
    private var sampleTime: TimeInterval?
    private var smoothedBytesPerSecond: Double?
    private var lastDispatchTime: TimeInterval?
    private let lock = NSLock()

    func consume(_ progress: DownloadUtils.DownloadProgress,
                 totalBytes: Int64,
                 now suppliedNow: TimeInterval? = nil) -> SpeechModelProgressUpdate {
        lock.lock()
        defer { lock.unlock() }

        let now = suppliedNow ?? ProcessInfo.processInfo.systemUptime
        let title = speechModelStartupStatusTitle(progress)
        let fraction = speechModelStartupProgressValue(progress)
        let phase = speechModelStartupPhaseName(progress)
        let phaseChanged = phase != lastPhase

        if phaseChanged {
            lastDownloadedBytes = nil
            sampleBytes = nil
            sampleTime = nil
            smoothedBytesPerSecond = nil
        }

        var metrics: SpeechModelDownloadMetrics?
        var didAdvance = phaseChanged
        if case .downloading(_, let totalFiles) = progress.phase,
           totalFiles > 0,
           totalBytes > 0 {
            let rawFraction = min(max(progress.fractionCompleted / 0.5, 0), 1)
            let downloadedBytes = min(
                totalBytes,
                max(0, Int64((Double(totalBytes) * rawFraction).rounded(.down)))
            )

            if let previous = lastDownloadedBytes {
                didAdvance = downloadedBytes > previous
            }
            lastDownloadedBytes = downloadedBytes

            if let previousBytes = sampleBytes,
               let previousTime = sampleTime {
                let elapsed = now - previousTime
                let byteDelta = downloadedBytes - previousBytes
                if byteDelta < 0 {
                    sampleBytes = downloadedBytes
                    sampleTime = now
                    smoothedBytesPerSecond = nil
                } else if elapsed >= 0.2, byteDelta > 0 {
                    let instantaneous = Double(byteDelta) / elapsed
                    if instantaneous.isFinite, instantaneous > 0 {
                        if let smoothed = smoothedBytesPerSecond {
                            smoothedBytesPerSecond = (smoothed * 0.72) + (instantaneous * 0.28)
                        } else {
                            smoothedBytesPerSecond = instantaneous
                        }
                    }
                    sampleBytes = downloadedBytes
                    sampleTime = now
                }
            } else {
                sampleBytes = downloadedBytes
                sampleTime = now
            }

            let speed = smoothedBytesPerSecond.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            let remaining = speed.flatMap { measuredSpeed -> Double? in
                let seconds = Double(max(0, totalBytes - downloadedBytes)) / measuredSpeed
                return seconds.isFinite ? seconds : nil
            }
            metrics = SpeechModelDownloadMetrics(
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                bytesPerSecond: speed,
                estimatedSecondsRemaining: remaining
            )
        }

        let timedRefresh = lastDispatchTime.map { now - $0 >= 0.5 } ?? true
        let downloadFinished = phase == "downloading" && fraction == 1
        let shouldDispatch: Bool
        if phase == "downloading" {
            shouldDispatch = phaseChanged || timedRefresh || downloadFinished
        } else {
            shouldDispatch = phaseChanged || title != lastTitle || fraction != lastFraction
        }

        if shouldDispatch {
            lastDispatchTime = now
        }
        lastTitle = title
        lastFraction = fraction
        lastPhase = phase
        return SpeechModelProgressUpdate(title: title,
                                         fraction: fraction,
                                         phase: phase,
                                         metrics: metrics,
                                         didAdvance: didAdvance,
                                         shouldDispatch: shouldDispatch)
    }
}

func speechModelNetworkProgressIsStalled(
    phase: String?,
    progressUpdatedAt: TimeInterval?,
    now: TimeInterval = Date().timeIntervalSince1970,
    threshold: TimeInterval = 12
) -> Bool {
    guard phase == "downloading" || phase == "listing" else { return false }
    guard let progressUpdatedAt else { return false }
    return (now - progressUpdatedAt) >= threshold
}

func localizedModelByteCount(_ bytes: Int64, language: InterfaceLanguage = .russian) -> String {
    let value: Double
    let unit: String
    if bytes >= 1_000_000_000 {
        value = Double(bytes) / 1_000_000_000
        unit = language == .russian ? "ГБ" : "GB"
    } else if bytes >= 1_000_000 {
        value = Double(bytes) / 1_000_000
        unit = language == .russian ? "МБ" : "MB"
    } else {
        value = Double(bytes) / 1_000
        unit = language == .russian ? "КБ" : "KB"
    }
    let digits = value < 10 ? 1 : 0
    return "\(localizedModelDecimal(value, digits: digits, language: language)) \(unit)"
}

func localizedModelDownloadSpeed(_ bytesPerSecond: Double, language: InterfaceLanguage = .russian) -> String {
    let value: Double
    let unit: String
    if bytesPerSecond >= 1_000_000 {
        value = bytesPerSecond / 1_000_000
        unit = language == .russian ? "МБ/с" : "MB/s"
    } else {
        value = bytesPerSecond / 1_000
        unit = language == .russian ? "КБ/с" : "KB/s"
    }
    let digits = value < 10 ? 1 : 0
    return "\(localizedModelDecimal(value, digits: digits, language: language)) \(unit)"
}

func localizedModelDuration(_ seconds: Double, language: InterfaceLanguage = .russian) -> String {
    let rounded = max(1, Int(seconds.rounded()))
    if rounded < 60 {
        return language == .russian ? "\(rounded) с" : "\(rounded)s"
    }
    let minutes = rounded / 60
    let remainder = rounded % 60
    if remainder == 0 {
        return language == .russian ? "\(minutes) мин" : "\(minutes)m"
    }
    return language == .russian ? "\(minutes) мин \(remainder) с" : "\(minutes)m \(remainder)s"
}

func localizedModelDecimal(_ value: Double, digits: Int, language: InterfaceLanguage = .russian) -> String {
    let result = String(format: "%.\(digits)f", value)
    return language == .russian ? result.replacingOccurrences(of: ".", with: ",") : result
}

func localizedModelDownloadNetworkHint(stalled: Bool, language: InterfaceLanguage = .russian) -> String {
    if stalled {
        return localizedText(
            "Прогресс остановился. Включите или выключите VPN, попробуйте другой VPN либо сеть.",
            "Progress has stopped. Toggle VPN, try another VPN, or switch networks.",
            language: language
        )
    }
    return localizedText(
        "Медленно? Включите или выключите VPN, попробуйте другой VPN либо сеть.",
        "Slow? Toggle VPN, try another VPN, or switch networks.",
        language: language
    )
}
