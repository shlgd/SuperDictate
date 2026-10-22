import AVFoundation
import Foundation

final class RealtimeAudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var squares = 0.0
    private var samples = 0
    private var level: Float = 0
    private var notchLevel: Float = 0
    private var rms = 0.0
    private var sequence: UInt64 = 0

    func setActive(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        active = value
        squares = 0
        samples = 0
        level = 0
        notchLevel = 0
        rms = 0
        sequence &+= 1
    }

    func consume(frames: AVAudioFrameCount, buffers: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        guard frames > 0, sampleRate > 0, lock.try() else { return }
        defer { lock.unlock() }
        guard active else { return }
        var strongest = 0.0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)) {
            guard let source = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            for channel in 0..<channels {
                var energy = 0.0
                for frame in 0..<Int(frames) {
                    let value = source[frame * channels + channel]
                    if value.isFinite {
                        let bounded = max(-1, min(1, value))
                        energy += Double(bounded * bounded)
                    }
                }
                strongest = max(strongest, energy)
            }
        }
        squares += strongest
        samples += Int(frames)
        guard Double(samples) >= sampleRate * 0.008 else { return }
        rms = sqrt(squares / Double(samples))
        level = normalizedAudioLevel(sumSquares: squares, sampleCount: samples)
        notchLevel = normalizedNotchAudioLevel(sumSquares: squares, sampleCount: samples)
        squares = 0
        samples = 0
        sequence &+= 1
    }

    func snapshot(forNotch: Bool = false) -> (level: Float, sequence: UInt64, rms: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (active ? (forNotch ? notchLevel : level) : 0, sequence, rms)
    }
}
