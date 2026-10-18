import Foundation

/// Converts renderer loop-counter samples into measured boundary intervals.
/// The first observed loop establishes a baseline; later samples report the
/// average elapsed seconds per loop, including skipped counters.
struct LoopBoundaryTiming: Equatable {
    private(set) var lastLoopCount = 0
    private(set) var lastLoopTime: Double?

    mutating func record(loopCount: Int, at time: Double) -> Double? {
        guard loopCount >= 0, time.isFinite else { return nil }
        guard loopCount > lastLoopCount else { return nil }
        let delta = loopCount - lastLoopCount
        let interval = lastLoopTime.map { (time - $0) / Double(delta) }
        lastLoopCount = loopCount
        lastLoopTime = time
        guard let interval, interval.isFinite, interval >= 0 else { return nil }
        return interval
    }
}
