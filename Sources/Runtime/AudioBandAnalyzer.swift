import Foundation

/// Constant-memory crossover envelopes, not a recording or an FFT history.
struct AudioBandAnalyzer {
    private struct Filter {
        var dc = 0.0, low = 0.0, high = 0.0
        mutating func sample(_ input: Double, dcCoefficient: Double, lowCoefficient: Double, highCoefficient: Double) -> (Double, Double, Double, Double) {
            let input = input.isFinite ? min(4, max(-4, input)) : 0
            dc += dcCoefficient * (input - dc)
            let value = input - dc
            low += lowCoefficient * (value - low)
            high += highCoefficient * (value - high)
            let mid = high - low, treble = value - high
            return (value * value, low * low, mid * mid, treble * treble)
        }
    }
    private let sampleRate: Double
    private let dcCoefficient: Double, lowCoefficient: Double, highCoefficient: Double
    private var left = Filter(), right = Filter()
    private var sums = SceneAudioLevels()
    private var energy = SceneAudioLevels()
    private var count = 0
    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { throw SceneError.invalid("Unsupported audio sample rate.") }
        self.sampleRate = sampleRate
        dcCoefficient = -expm1(-2 * .pi * 20 / sampleRate)
        lowCoefficient = -expm1(-2 * .pi * 200 / sampleRate)
        highCoefficient = -expm1(-2 * .pi * 2_000 / sampleRate)
    }
    mutating func append(left l: Float, right r: Float) {
        let a = left.sample(Double(l), dcCoefficient: dcCoefficient, lowCoefficient: lowCoefficient, highCoefficient: highCoefficient)
        let b = right.sample(Double(r), dcCoefficient: dcCoefficient, lowCoefficient: lowCoefficient, highCoefficient: highCoefficient)
        sums.level += (a.0 + b.0) * 0.5
        sums.bass += (a.1 + b.1) * 0.5
        sums.mid += (a.2 + b.2) * 0.5
        sums.treble += (a.3 + b.3) * 0.5
        count += 1
    }
    mutating func finishBlock() -> SceneAudioLevels {
        guard count > 0 else { return SceneAudioLevels() }
        let elapsed = Double(count) / sampleRate
        func envelope(_ sum: Double, _ previous: Double) -> Double {
            let target = sum / Double(count)
            let alpha = -expm1(-elapsed / (target > previous ? 0.03 : 0.18))
            return previous + alpha * (target - previous)
        }
        energy = .init(level: envelope(sums.level, energy.level), bass: envelope(sums.bass, energy.bass),
                       mid: envelope(sums.mid, energy.mid), treble: envelope(sums.treble, energy.treble))
        sums = .init(); count = 0
        return .init(level: min(1, sqrt(max(0, energy.level))), bass: min(1, sqrt(max(0, energy.bass))),
                     mid: min(1, sqrt(max(0, energy.mid))), treble: min(1, sqrt(max(0, energy.treble))))
    }
}
