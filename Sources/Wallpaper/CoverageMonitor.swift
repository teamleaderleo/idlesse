import AppKit

/// Rests a display surface when other windows cover it. Unlike
/// `occlusionState` (which always reads occluded for below-icon windows),
/// this measures actual coverage from the on-screen window list, so a bare
/// desktop reads ~0 and a fullscreen app reads 1.
final class CoverageMonitor {
    /// `WallpaperController` still consumes coverage as a scalar. The raw
    /// measurement is held on the current side of this boundary until the
    /// hysteresis policy confirms a transition.
    let threshold = 0.9

    /// Enter rest only when essentially the whole wallpaper is hidden.
    let restThreshold = 0.95
    /// Resume before a substantial portion of the wallpaper is exposed.
    let resumeThreshold = 0.85
    /// Require repeat observations in either direction before changing state.
    let stableSamples = 2

    /// Sampling cells per axis for the coverage estimate.
    private let cells = 12
    /// A long sampling gap means the prior desktop state is stale. Starting
    /// active is safer than carrying a covered decision across sleep/rebuilds.
    private let staleAfter: TimeInterval = 8
    private let now: () -> TimeInterval

    struct RestDecision {
        let resting: Bool
        let changed: Bool
        let pendingTarget: Bool?
        let pendingSamples: Int
    }

    struct RestPolicy {
        private(set) var resting = false
        private(set) var pendingTarget: Bool?
        private(set) var pendingSamples = 0

        mutating func update(fraction: Double, restThreshold: Double,
                             resumeThreshold: Double, stableSamples: Int) -> RestDecision {
            precondition(restThreshold > resumeThreshold)
            let required = max(1, stableSamples)
            let candidate: Bool?
            if resting {
                candidate = fraction <= resumeThreshold ? false : nil
            } else {
                candidate = fraction >= restThreshold ? true : nil
            }

            guard let candidate else {
                pendingTarget = nil
                pendingSamples = 0
                return RestDecision(resting: resting, changed: false,
                    pendingTarget: nil, pendingSamples: 0)
            }

            if pendingTarget == candidate {
                pendingSamples += 1
            } else {
                pendingTarget = candidate
                pendingSamples = 1
            }

            guard pendingSamples >= required else {
                return RestDecision(resting: resting, changed: false,
                    pendingTarget: pendingTarget, pendingSamples: pendingSamples)
            }

            let changed = resting != candidate
            resting = candidate
            pendingTarget = nil
            pendingSamples = 0
            return RestDecision(resting: resting, changed: changed,
                pendingTarget: nil, pendingSamples: 0)
        }
    }

    private struct SurfaceState {
        var policy = RestPolicy()
        var sampledAt: TimeInterval
    }

    private struct Measurement {
        let fraction: Double
        let coveringWindows: Int
        let translucentSkipped: Int
        let chromeSkipped: Int
    }

    private var states: [String: SurfaceState] = [:]

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// System chrome can publish large opaque-looking bounds that do not mean
    /// the wallpaper is actually hidden. Keep the list deliberately narrow;
    /// unknown UI should cost a little GPU instead of causing a false rest.
    private static let chromeOwners: Set<String> = ["Dock", "Notification Center", "Screenshot"]
    private static let minimumOpaqueAlpha = 0.98

    static func countsAsOpaqueWindow(alpha: Double) -> Bool {
        alpha >= minimumOpaqueAlpha
    }

    /// Fraction of `rect` (Cocoa screen coordinates) covered by on-screen
    /// windows above `level`, excluding `ownNumbers` and our own process.
    ///
    /// The returned scalar remains compatible with the controller's existing
    /// `>= threshold` decision, but hysteresis/stability can hold a raw sample
    /// on the previous side of that boundary until a transition is confirmed.
    /// Every sample logs its raw fraction and pending policy state.
    func coverage(of rect: NSRect, above level: Int, excluding ownNumbers: Set<CGWindowID>, ownPID: Int) -> Double {
        let measurement = measureCoverage(of: rect, above: level, excluding: ownNumbers, ownPID: ownPID)
        let sampledAt = now()
        let surfaceGeneration = ownNumbers.sorted().map { String($0) }.joined(separator: ",")
        let key = NSStringFromRect(rect) + "@\(level)#\(surfaceGeneration)"
        var state = states[key] ?? SurfaceState(sampledAt: sampledAt)
        if sampledAt - state.sampledAt > staleAfter {
            state.policy = RestPolicy()
        }
        state.sampledAt = sampledAt
        let decision = state.policy.update(fraction: measurement.fraction,
            restThreshold: restThreshold, resumeThreshold: resumeThreshold,
            stableSamples: stableSamples)
        states[key] = state

        let pending: String
        if let target = decision.pendingTarget {
            pending = "\(target ? "rest" : "resume"):\(decision.pendingSamples)/\(stableSamples)"
        } else {
            pending = "none"
        }
        let raw = String(format: "%.3f", measurement.fraction)
        Self.appendLine("Idlesse-coverage-sample frame=\(NSStringFromRect(rect)) raw=\(raw) resting=\(decision.resting ? 1 : 0) transition=\(decision.changed ? 1 : 0) pending=\(pending) windows=\(measurement.coveringWindows) translucentSkipped=\(measurement.translucentSkipped) chromeSkipped=\(measurement.chromeSkipped)")

        // Keep the controller on the policy-selected side of its legacy scalar
        // threshold. Confirmed transitions naturally return the raw value.
        return decision.resting ? max(measurement.fraction, threshold) : min(measurement.fraction, threshold.nextDown)
    }

    private func measureCoverage(of rect: NSRect, above level: Int,
                                 excluding ownNumbers: Set<CGWindowID>, ownPID: Int) -> Measurement {
        guard let mainHeight = NSScreen.main?.frame.height, rect.width > 0, rect.height > 0 else {
            return Measurement(fraction: 0, coveringWindows: 0, translucentSkipped: 0, chromeSkipped: 0)
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], CGWindowID(0)) as? [[String: Any]] else {
            return Measurement(fraction: 0, coveringWindows: 0, translucentSkipped: 0, chromeSkipped: 0)
        }
        var covering: [NSRect] = []
        var translucentSkipped = 0
        var chromeSkipped = 0
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

            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if Self.chromeOwners.contains(owner) {
                chromeSkipped += 1
                continue
            }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard Self.countsAsOpaqueWindow(alpha: alpha) else {
                translucentSkipped += 1
                continue
            }

            // Quartz bounds use a top-left origin relative to the main display;
            // AppKit uses a bottom-left origin. Negative Quartz Y coordinates
            // correctly map displays arranged above the main screen.
            let cocoa = NSRect(x: CGFloat(x), y: mainHeight - CGFloat(y) - CGFloat(h),
                width: CGFloat(w), height: CGFloat(h))
            let hit = cocoa.intersection(rect)
            if !hit.isNull && !hit.isEmpty { covering.append(hit) }
        }
        return Measurement(fraction: Self.coveredFraction(of: rect, by: covering, cells: cells),
            coveringWindows: covering.count, translucentSkipped: translucentSkipped,
            chromeSkipped: chromeSkipped)
    }

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

    /// Grid-sampled union coverage. Pure for tests.
    static func coveredFraction(of rect: NSRect, by covering: [NSRect], cells: Int = 12) -> Double {
        guard rect.width > 0, rect.height > 0, !covering.isEmpty else { return 0 }
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
