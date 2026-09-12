import AppKit

/// Estimates whether other windows cover an Idlesse desktop surface. Raw
/// measurement stays separate from rest policy so coverage remains observable
/// while hysteresis and stability decide renderer pause/resume transitions.
final class CoverageMonitor {
    struct Measurement: Equatable {
        let fraction: Double
        let consideredWindows: Int
        let ignoredChromeWindows: Int
        let ignoredTransparentWindows: Int
    }

    let policy: CoverageRestPolicy
    private let cells: Int
    private let staleAfter: TimeInterval
    private let now: () -> TimeInterval

    private struct TrackerState {
        var tracker: CoverageRestPolicy.Tracker
        var sampledAt: TimeInterval
    }

    private var trackers: [String: TrackerState] = [:]

    init(policy: CoverageRestPolicy = CoverageRestPolicy(), cells: Int = 12,
         staleAfter: TimeInterval = 8,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(cells > 0)
        precondition(staleAfter > 0)
        self.policy = policy
        self.cells = cells
        self.staleAfter = staleAfter
        self.now = now
    }

    /// Full-display utility/chrome windows can publish opaque-looking bounds
    /// while drawing only a strip or transient affordance. Keep these excluded;
    /// an unknown case should cost extra rendering instead of causing a false rest.
    private static let chromeOwners: Set<String> = [
        "Dock", "Notification Center", "Screenshot", "Control Center",
        "SystemUIServer", "Window Server"
    ]
    private static let minimumOpaqueAlpha = 0.98

    static func countsAsOpaqueWindow(alpha: Double) -> Bool {
        alpha >= minimumOpaqueAlpha
    }

    func measurement(of rect: NSRect, above level: Int,
                     excluding ownNumbers: Set<CGWindowID>, ownPID: Int) -> Measurement {
        guard let mainHeight = NSScreen.main?.frame.height,
              rect.width > 0, rect.height > 0 else {
            return Measurement(fraction: 0, consideredWindows: 0,
                               ignoredChromeWindows: 0, ignoredTransparentWindows: 0)
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], CGWindowID(0)) as? [[String: Any]] else {
            return Measurement(fraction: 0, consideredWindows: 0,
                               ignoredChromeWindows: 0, ignoredTransparentWindows: 0)
        }
        var covering: [NSRect] = []
        var considered = 0
        var ignoredChrome = 0
        var ignoredTransparent = 0
        for entry in list {
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !ownNumbers.contains(CGWindowID(number)),
                  (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue != ownPID,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer > level,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let h = (bounds["Height"] as? NSNumber)?.doubleValue,
                  w > 0, h > 0 else { continue }

            let cocoa = NSRect(x: CGFloat(x), y: mainHeight - CGFloat(y) - CGFloat(h),
                               width: CGFloat(w), height: CGFloat(h))
            let hit = cocoa.intersection(rect)
            guard !hit.isNull, !hit.isEmpty else { continue }

            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if Self.chromeOwners.contains(owner) {
                ignoredChrome += 1
                continue
            }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard Self.countsAsOpaqueWindow(alpha: alpha) else {
                ignoredTransparent += 1
                continue
            }
            considered += 1
            covering.append(hit)
        }
        return Measurement(fraction: Self.coveredFraction(of: rect, by: covering, cells: cells),
                           consideredWindows: considered,
                           ignoredChromeWindows: ignoredChrome,
                           ignoredTransparentWindows: ignoredTransparent)
    }

    func coverage(of rect: NSRect, above level: Int,
                  excluding ownNumbers: Set<CGWindowID>, ownPID: Int) -> Double {
        measurement(of: rect, above: level, excluding: ownNumbers, ownPID: ownPID).fraction
    }

    func evaluate(displayKey: String, fraction: Double,
                  currentResting: Bool) -> CoverageRestPolicy.Decision {
        let sampledAt = now()
        if let state = trackers[displayKey], sampledAt - state.sampledAt > staleAfter {
            let gap = sampledAt - state.sampledAt
            trackers[displayKey] = TrackerState(
                tracker: CoverageRestPolicy.Tracker(isResting: false), sampledAt: sampledAt)
            Self.appendLine(String(format:
                "Idlesse-coverage-reset display=%@ reason=stale gap=%.2f previousResting=%d",
                displayKey, gap, currentResting ? 1 : 0))
            if currentResting {
                return CoverageRestPolicy.Decision(isResting: false, changed: true,
                                                   candidate: nil, consecutiveSamples: 0)
            }
            var tracker = CoverageRestPolicy.Tracker(isResting: false)
            let decision = tracker.sample(fraction, policy: policy)
            trackers[displayKey] = TrackerState(tracker: tracker, sampledAt: sampledAt)
            return decision
        }

        var tracker = trackers[displayKey]?.tracker ?? CoverageRestPolicy.Tracker(isResting: currentResting)
        tracker.synchronize(isResting: currentResting)
        let decision = tracker.sample(fraction, policy: policy)
        trackers[displayKey] = TrackerState(tracker: tracker, sampledAt: sampledAt)
        return decision
    }

    func reset() { trackers.removeAll() }

    private static func appendLine(_ line: String) {
        NSLog("%@", line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/idlesse-state.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func coveredFraction(of rect: NSRect, by covering: [NSRect], cells: Int = 12) -> Double {
        guard rect.width > 0, rect.height > 0, cells > 0, !covering.isEmpty else { return 0 }
        var hit = 0
        var total = 0
        for ix in 0..<cells {
            for iy in 0..<cells {
                let point = NSPoint(
                    x: rect.minX + rect.width * (CGFloat(ix) + 0.5) / CGFloat(cells),
                    y: rect.minY + rect.height * (CGFloat(iy) + 0.5) / CGFloat(cells))
                total += 1
                if covering.contains(where: { $0.contains(point) }) { hit += 1 }
            }
        }
        return Double(hit) / Double(max(1, total))
    }
}
