import Foundation

/// One monotonic timeline shared by every surface of an active scene.
/// Video loops are not frame-locked to this clock yet.
final class SceneClock {
    private let now: () -> TimeInterval
    private var anchor: TimeInterval
    private var accumulated: TimeInterval = 0
    private(set) var playbackRate: Double = 1
    private(set) var loopRange: Range<TimeInterval>?
    private(set) var isPaused = true
    /// Explicit host opt-in, never granted by a package manifest.
    var pointerEnabled = false
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        anchor = now()
    }
    var time: TimeInterval { wrapped(accumulated + (isPaused ? 0 : max(0, now() - anchor) * playbackRate)) }
    private func wrapped(_ value: TimeInterval) -> TimeInterval {
        guard let loopRange else { return value }
        let duration = loopRange.upperBound - loopRange.lowerBound
        return loopRange.lowerBound + max(0, value - loopRange.lowerBound).truncatingRemainder(dividingBy: duration)
    }
    /// Atomic transport edit. These settings are host-session state, not authored scene data.
    func configure(time: TimeInterval, rate: Double, loop: Range<TimeInterval>?) throws {
        guard time.isFinite, (0...86400).contains(time), rate.isFinite, (0.1...4).contains(rate) else {
            throw SceneError.invalid("Use a time of 0–86400 seconds and a playback rate of 0.1–4.")
        }
        if let loop {
            guard loop.lowerBound.isFinite, loop.upperBound.isFinite, loop.lowerBound >= 0,
                  loop.upperBound <= 86400, loop.upperBound - loop.lowerBound >= 0.01 else {
                throw SceneError.invalid("Use a loop within 0–86400 seconds, at least 0.01 seconds long.")
            }
        }
        loopRange = loop
        playbackRate = rate
        accumulated = wrapped(time)
        anchor = now()
    }
    func seek(to time: TimeInterval) throws {
        try configure(time: time, rate: playbackRate, loop: loopRange)
    }
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        accumulated = time
        anchor = now()
        isPaused = paused
    }
}
