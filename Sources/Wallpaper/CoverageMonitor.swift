import AppKit

/// Rests a display surface when other windows cover it. Unlike
/// `occlusionState` (which always reads occluded for below-icon windows),
/// this measures actual coverage from the on-screen window list, so a bare
/// desktop reads ~0 and a fullscreen app reads 1.
final class CoverageMonitor {
    /// Fraction of a surface that must be covered before it rests.
    var threshold = 0.9
    /// Sampling cells per axis for the coverage estimate.
    private let cells = 12

    /// Fraction of `rect` (Cocoa screen coordinates) covered by on-screen
    /// windows above `level`, excluding `ownNumbers` and our own process.
    /// System chrome (Dock, Notification Center, screenshot UI) reports
    /// full-display opaque bounds without visually covering anything, so it
    /// is excluded by owner name.
    private static let chromeOwners: Set<String> = ["Dock", "Notification Center", "Screenshot"]
    func coverage(of rect: NSRect, above level: Int, excluding ownNumbers: Set<CGWindowID>, ownPID: Int) -> Double {
        guard let mainHeight = NSScreen.main?.frame.height, rect.width > 0, rect.height > 0 else { return 0 }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], CGWindowID(0)) as? [[String: Any]] else { return 0 }
        var covering: [NSRect] = []
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  !ownNumbers.contains(CGWindowID(number)),
                  (entry[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  !Self.chromeOwners.contains(entry[kCGWindowOwnerName as String] as? String ?? ""),
                  let layer = entry[kCGWindowLayer as String] as? Int, layer > level,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"], w > 0, h > 0 else { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? CGFloat) ?? 1
            guard alpha > 0.5 else { continue }
            // Quartz bounds are top-left origin; convert to Cocoa bottom-left.
            let cocoa = NSRect(x: x, y: mainHeight - y - h, width: w, height: h)
            let hit = cocoa.intersection(rect)
            if !hit.isNull && !hit.isEmpty { covering.append(hit) }
        }
        return Self.coveredFraction(of: rect, by: covering, cells: cells)
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
