import AppKit

enum AudioSmoke {
    /// Explicit manual test: plays a quiet fixture; records only scalar peak levels.
    static func run(url: URL) throws {
        let input = SystemAudioInput.shared
        let first = UUID(), second = UUID()
        defer { try? input.setActive(false, client: first); try? input.setActive(false, client: second) }
        try input.setActive(true, client: first)
        try input.setActive(true, client: second)
        try input.setActive(false, client: first)
        precondition(input.isCapturing, "One remaining host must keep the shared input alive")
        guard let sound = NSSound(contentsOf: url, byReference: true) else { throw SceneError.invalid("Could not open the test tone.") }
        sound.volume = 0.1
        guard sound.play() else { throw SceneError.invalid("Could not play the test tone.") }
        defer { sound.stop() }
        let deadline = Date().addingTimeInterval(5)
        var peak = SceneAudioLevels()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let value = input.snapshot()
            peak.level = max(peak.level, value.level)
            peak.bass = max(peak.bass, value.bass)
            peak.mid = max(peak.mid, value.mid)
            peak.treble = max(peak.treble, value.treble)
        }
        try input.setActive(false, client: second)
        precondition(!input.isCapturing && input.snapshot().level == 0)
        guard peak.level > 0.00001 else { throw SceneError.invalid("No nonzero system audio arrived. Check the system-audio permission and output device.") }
        let clock = SceneClock()
        var failure: String?
        let session = SceneAudioSession(clock: clock) { failure = $0 }
        clock.audioEnabled = true
        precondition(!input.isCapturing)
        clock.setPaused(false)
        guard failure == nil else { throw SceneError.invalid(failure!) }
        precondition(input.isCapturing)
        clock.setPaused(true)
        precondition(!input.isCapturing)
        withExtendedLifetime(session) {}
        print(String(format: "Native audio passed: level %.5f, bass %.5f, mid %.5f, treble %.5f; shared clients and pause teardown passed", peak.level, peak.bass, peak.mid, peak.treble))
    }
}
