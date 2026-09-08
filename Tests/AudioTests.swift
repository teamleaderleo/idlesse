import Foundation

@main struct AudioTests {
    static func main() throws {
        func tone(_ hz: Double, sampleRate: Double = 48_000, inverted: Bool = false) throws -> SceneAudioLevels {
            var analyzer = try AudioBandAnalyzer(sampleRate: sampleRate)
            var result = SceneAudioLevels()
            for index in 0..<Int(sampleRate) {
                let value = Float(sin(Double(index) * 2 * .pi * hz / sampleRate) * 0.5)
                analyzer.append(left: value, right: inverted ? -value : value)
                if index % 256 == 255 { result = analyzer.finishBlock() }
            }
            return result
        }
        for rate in [44_100.0, 48_000, 96_000] {
            let bass = try tone(80, sampleRate: rate)
            let mid = try tone(800, sampleRate: rate)
            let treble = try tone(8_000, sampleRate: rate)
            precondition(bass.bass > bass.mid * 2 && bass.bass > bass.treble * 2)
            precondition(mid.mid > mid.bass * 2 && mid.mid > mid.treble)
            precondition(treble.treble > treble.mid * 2 && treble.treble > treble.bass * 2)
            precondition((0.3...0.4).contains(mid.level))
        }
        let normal = try tone(800)
        let inverted = try tone(800, inverted: true)
        precondition(abs(normal.level - inverted.level) < 0.000001, "Opposite-phase stereo must not cancel")
        var analyzer = try AudioBandAnalyzer(sampleRate: 48_000)
        for _ in 0..<512 { analyzer.append(left: .nan, right: .infinity) }
        precondition(analyzer.finishBlock().level == 0)
        for index in 0..<48_000 {
            analyzer.append(left: Float(sin(Double(index) * 0.1)), right: 0)
            if index % 256 == 255 { _ = analyzer.finishBlock() }
        }
        var silent = SceneAudioLevels()
        for index in 0..<96_000 {
            analyzer.append(left: 0, right: 0)
            if index % 256 == 255 { silent = analyzer.finishBlock() }
        }
        precondition(silent.level < 0.005)
        let clock = SceneClock()
        var demand = [Bool]()
        clock.audioActivityChanged = { demand.append($0) }
        clock.audioEnabled = true
        clock.setPaused(false)
        clock.setPaused(true)
        clock.audioEnabled = false
        precondition(demand == [false, true, false, false])
        print("Audio checks passed: bands, sample rates, stereo phase, silence, invalid samples, and pause demand")
    }
}
