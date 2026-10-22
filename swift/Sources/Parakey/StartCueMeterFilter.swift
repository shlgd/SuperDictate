import Foundation

struct StartCueMeterFilter {
    struct Energy {
        let raw: Double
        let filtered: Double
        let sampleCount: Int

        func mixed(weight: Double) -> Double {
            let amount = max(0, min(1, weight))
            return raw * (1 - amount) + filtered * amount
        }
    }

    private struct Notch {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var z1 = 0.0
        var z2 = 0.0

        init(sampleRate: Double, frequency: Double, quality: Double) {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * quality)
            let inverse = 1 / (1 + alpha)
            b0 = inverse
            b1 = -2 * cos(omega) * inverse
            b2 = inverse
            a1 = b1
            a2 = (1 - alpha) * inverse
        }

        mutating func process(_ value: Double) -> Double {
            let output = b0 * value + z1
            z1 = b1 * value - a1 * output + z2
            z2 = b2 * value - a2 * output
            return output
        }
    }

    private var first: Notch
    private var second: Notch
    private var third: Notch
    private var secondHarmonic: Notch
    private var secondHarmonicTail: Notch
    private var thirdHarmonic: Notch

    init(sampleRate: Double) {
        first = Notch(sampleRate: sampleRate, frequency: 261.626, quality: 4)
        second = Notch(sampleRate: sampleRate, frequency: 261.626, quality: 4)
        third = Notch(sampleRate: sampleRate, frequency: 261.626, quality: 4)
        secondHarmonic = Notch(sampleRate: sampleRate, frequency: 523.252, quality: 20)
        secondHarmonicTail = Notch(sampleRate: sampleRate, frequency: 523.252, quality: 20)
        thirdHarmonic = Notch(sampleRate: sampleRate, frequency: 784.878, quality: 24)
    }

    mutating func measure(_ samples: [Float]) -> Energy {
        var raw = 0.0
        var filtered = 0.0
        var count = 0
        for sample in samples {
            let value = sample.isFinite ? Double(max(-1, min(1, sample))) : 0
            let fundamental = third.process(second.process(first.process(value)))
            let output = thirdHarmonic.process(secondHarmonicTail.process(secondHarmonic.process(fundamental)))
            guard sample.isFinite else { continue }
            raw += value * value
            filtered += output * output
            count += 1
        }
        return Energy(raw: raw, filtered: filtered, sampleCount: count)
    }
}
