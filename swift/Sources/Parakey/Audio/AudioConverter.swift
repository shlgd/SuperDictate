// Parakey — push-to-talk dictation for macOS Apple Silicon.
// Audio / AudioConverter.swift

import AVFoundation
import Foundation

final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideBuffer {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}

func selectedMonoMixChannelIndices(channelRMS: [Double]) -> [Int] {
    let peak = channelRMS.max() ?? 0
    let active = channelRMS.enumerated()
        .filter { pair in peak > 0 && pair.element >= peak * 0.25 }
        .map { $0.offset }
    return active.isEmpty ? [0] : active
}

func channelRMSValues(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                      channelCount: Int,
                      frameCount: Int) -> [Double] {
    guard channelCount > 0, frameCount > 0 else { return [] }
    var rms = Array(repeating: 0.0, count: channelCount)
    for channelIndex in 0..<channelCount {
        var sumSquares = 0.0
        let source = channels[channelIndex]
        for frameIndex in 0..<frameCount {
            let sample = source[frameIndex]
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
        }
        rms[channelIndex] = sqrt(sumSquares / Double(frameCount))
    }
    return rms
}

func writeMonoMix(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                  selectedChannels: [Int],
                  frameCount: Int,
                  to mono: UnsafeMutablePointer<Float>) {
    guard frameCount > 0 else { return }
    let selectedChannels = selectedChannels.isEmpty ? [0] : selectedChannels
    let scale = Float(1.0 / Double(selectedChannels.count))
    for frameIndex in 0..<frameCount {
        var mixed: Float = 0
        for channelIndex in selectedChannels {
            mixed += channels[channelIndex][frameIndex] * scale
        }
        mono[frameIndex] = mixed
    }
}

func normalizedAudioLevel(from samples: [Float]) -> Float {
    var sumSquares: Double = 0
    var count = 0

    for sample in samples where sample.isFinite {
        let clamped = max(-1, min(1, sample))
        sumSquares += Double(clamped * clamped)
        count += 1
    }

    return normalizedAudioLevel(sumSquares: sumSquares, sampleCount: count)
}

func normalizedAudioLevel(sumSquares: Double, sampleCount: Int) -> Float {
    guard sampleCount > 0, sumSquares > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite, rms > 0 else { return 0 }

    // Voice-visibility meter curve
    let decibels = 20 * log10(rms)
    let gated = (decibels + 52) / 20
    guard gated > 0.06 else { return 0 }
    let lifted = pow(max(0, min(1, gated)), 0.42)
    return Float(max(0, min(1, lifted)))
}

func visibleRecordingLevel(rawLevel: Float) -> Float {
    guard rawLevel.isFinite else { return 0 }
    return max(0, min(1, rawLevel))
}

func recordingHUDPhaseSpeed(mode: RecordingHUDMode, level: Float) -> CGFloat {
    switch mode {
    case .recording:
        let voiceLevel = CGFloat(visibleRecordingLevel(rawLevel: level))
        return RECORDING_HUD_RECORDING_BASE_PHASE_SPEED
            + (voiceLevel * RECORDING_HUD_RECORDING_LEVEL_PHASE_SPEED)
    case .transcribing:
        return RECORDING_HUD_TRANSCRIBING_PHASE_SPEED
    case .error:
        return 0
    }
}
