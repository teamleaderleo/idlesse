import Foundation

/// One monotonic timeline shared by every surface of an active scene.
/// Video loops are not frame-locked to this clock yet.
final class SceneClock {
    private let now: () -> TimeInterval
    private var anchor: TimeInterval
    private var accumulated: TimeInterval = 0
    private(set) var isPaused = true
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        anchor = now()
    }
    var time: TimeInterval { accumulated + (isPaused ? 0 : max(0, now() - anchor)) }
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        accumulated = time
        anchor = now()
        isPaused = paused
    }
}
