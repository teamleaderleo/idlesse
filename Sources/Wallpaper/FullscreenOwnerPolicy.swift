import AppKit

/// Conservative geometry gate for a single fullscreen owner. The caller still
/// supplies the window-layer/name hint from the one CGWindowList sample.
enum FullscreenOwnerPolicy {
    static let edgeTolerance: CGFloat = 2

    static func coversDisplay(candidate: NSRect, display: NSRect,
                              tolerance: CGFloat = edgeTolerance) -> Bool {
        guard candidate.width > 0, candidate.height > 0, display.width > 0, display.height > 0 else { return false }
        return candidate.minX <= display.minX + tolerance && candidate.minY <= display.minY + tolerance &&
            candidate.maxX >= display.maxX - tolerance && candidate.maxY >= display.maxY - tolerance
    }

    static func qualifies(layer: Int, surfaceLevel: Int, windowName: String,
                          candidate: NSRect, display: NSRect,
                          opaque: Bool) -> Bool {
        guard opaque, coversDisplay(candidate: candidate, display: display) else { return false }
        // Elevated borderless windows are the common game/fullscreen case. A
        // layer-0 owner is accepted only when AppKit exposes no window title,
        // keeping ordinary titled/maximized windows out of this fast path.
        return layer > surfaceLevel || (layer == 0 && windowName.isEmpty)
    }
}
