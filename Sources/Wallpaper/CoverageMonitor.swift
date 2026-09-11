import AppKit

/// Estimates whether other windows cover an Idlesse desktop surface. The raw
/// estimate is deliberately separate from the rest policy: callers get a
/// conservative measurement, then `CoverageRestPolicy` adds hysteresis and
/// consecutive-sample stability before a renderer is paused or resumed.
final class CoverageMonitor {
    struct Measurement: Equatable {
        let fraction: Double
        let consideredWindows: Int
        let ignoredChromeWindows: Int
        let ignoredTransparentWindows: Int
    }

    let policy = CoverageRestPolicy()
    private let cells = 12
    private var trackers: [String: CoverageRestPolicy.Tracker] = [:]

    /// Full-display utility/chrome windows can report opaque geometry even when
    /// they only draw a strip, shelf or transient affordance. They are excluded
    /// so system chrome cannot make a bare desktop look fully covered.
    private static let chromeOwners: Set<String> = [
        "Dock", "Notification Center", "Screenshot", "Control Center",
        "SystemUIServer", "Window Server"
    ]

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
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  !ownNumbers.contains(CGWindowID(number)),
                  (entry[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer > level,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"], w > 0, h > 0 else { continue }
            let cocoa = NSRect(x: x, y: mainHeight - y - h, width: w, height: h)
            let hit = cocoa.intersection(rect)
            guard !hit.isNull, !hit.isEmpty else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if Self.chromeOwners.contains(owner) {
                ignoredChrome += 1
                continue
            }
            let alpha = (entry[kCGWindowAlpha as String] as? CGFloat) ?? 1
            // Coverage rest is an energy optimization, so ambiguous translucent
            // windows stay on the safe side and keep animation running.
            guard alpha >= 0.85 else {
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
        var tracker = trackers[displayKey] ?? CoverageRestPolicy.Tracker(isResting: currentResting)
        tracker.synchronize(isResting: currentResting)
        let decision = tracker.sample(fraction, policy: policy)
        trackers[displayKey] = tracker
        return decision
    }

    func reset() { trackers.removeAll() }

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
