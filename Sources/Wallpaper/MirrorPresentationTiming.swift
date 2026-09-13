import Foundation

/// Each pair is one copied frame, not two unrelated presentation counters.
/// Callback order is unspecified; retain only aggregate timing, never frames.
final class MirrorPresentationTiming {
    private let lock = NSLock()
    private var count = 0
    private var misses = 0
    private var total = 0.0
    private var maximum = 0.0

    func recordMiss() { lock.lock(); misses += 1; lock.unlock() }
    func makePair() -> Pair { Pair(owner: self) }
    private func record(delta: Double) {
        lock.lock()
        count += 1
        total += abs(delta)
        maximum = max(maximum, abs(delta))
        lock.unlock()
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return "no presented pairs; \(misses) missed copies" }
        return String(format: "%d pairs; mean |skew| %.2f ms; max %.2f ms; %d missed copies",
                      count, total / Double(count) * 1000, maximum * 1000, misses)
    }
    final class Pair {
        private let lock = NSLock()
        private let owner: MirrorPresentationTiming
        private var sourceTime: Double?
        private var mirrorTime: Double?
        private var completed = false
        init(owner: MirrorPresentationTiming) { self.owner = owner }
        func record(source: Bool, time: Double) {
            guard time.isFinite, time > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            guard !completed else { return }
            if source { sourceTime = time } else { mirrorTime = time }
            if let sourceTime, let mirrorTime {
                completed = true
                owner.record(delta: mirrorTime - sourceTime)
            }
        }
    }
}

/// A missed copy must be retried even when the source is paused or static.
/// Only an available drawable consumes the request; repeated ready callbacks
/// must not create an unbounded redraw loop.
struct MirrorFrameRecovery {
    private var pending = true
    mutating func missedCopy() { pending = true }
    mutating func drawableReady(available: Bool) -> Bool {
        guard available && pending else { return false }
        pending = false
        return true
    }
}
