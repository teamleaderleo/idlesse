import Foundation

/// Privacy-preserving creative host input derived from the same raw coverage
/// observation used by desktop rest. Scenes receive only this normalized value.
enum DesktopAttentionSignal {
    static let exposed = 1.0

    /// 1 means the desktop is fully exposed; 0 means the display is fully
    /// covered. Intermediate values follow the visible fraction directly.
    static func value(coverageFraction: Double) -> Double {
        guard coverageFraction.isFinite else { return exposed }
        return min(1, max(0, 1 - coverageFraction))
    }
}
