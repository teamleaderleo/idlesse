import Foundation

/// Privacy-preserving creative input derived from the existing coverage sample.
/// Scenes receive only how exposed the desktop is, never window identity.
enum DesktopAttentionSignal {
    static let exposed = 1.0

    /// 1 means fully exposed; 0 means fully covered. Invalid samples fail open
    /// so a transient observation problem cannot freeze a scene.
    static func value(coverageFraction: Double) -> Double {
        guard coverageFraction.isFinite else { return exposed }
        return min(1, max(0, 1 - coverageFraction))
    }
}
