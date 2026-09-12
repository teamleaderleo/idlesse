import AppKit

final class ImageCanvasView: NSView {
    /// Unit coordinates measured from the top-left; only used for aspect fill.
    var fillFocus: CGPoint? { didSet { needsDisplay = true } }
    var currentImage: NSImage? {
        didSet { needsDisplay = true }
    }

    var nextImage: NSImage? {
        didSet { needsDisplay = true }
    }

    var transitionProgress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var scalingMode: IdlesseScalingMode = .fit {
        didSet { needsDisplay = true }
    }

    var backdropColor: NSColor = .black {
        didSet { needsDisplay = true }
    }

    var message: String? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { backdropColor.alphaComponent == 1 }

    override func draw(_ dirtyRect: NSRect) {
        backdropColor.setFill()
        NSBezierPath(rect: bounds).fill()

        let progress = min(1, max(0, transitionProgress))

        if let currentImage {
            drawImage(currentImage, alpha: nextImage == nil ? 1 : 1 - progress)
        }

        if let nextImage {
            drawImage(nextImage, alpha: progress)
        }

        if currentImage == nil, let message {
            drawMessage(message)
        }
    }

    private func drawImage(_ image: NSImage, alpha: CGFloat) {
        guard alpha > 0, image.size.width > 0, image.size.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high

        image.draw(
            in: destinationRect(for: image),
            from: .zero,
            operation: .sourceOver,
            fraction: alpha,
            respectFlipped: true,
            hints: nil
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    func destinationRect(for image: NSImage) -> NSRect {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return .zero }

        let scale: CGFloat
        switch scalingMode {
        case .fit:
            scale = min(bounds.width / source.width, bounds.height / source.height)
        case .fill:
            scale = max(bounds.width / source.width, bounds.height / source.height)
        case .actual:
            scale = 1
        }

        let width = source.width * scale
        let height = source.height * scale

        if scalingMode == .fill, let focus = fillFocus,
           focus.x.isFinite, focus.y.isFinite {
            return NSRect(x: bounds.minX - (width - bounds.width) * min(1, max(0, focus.x)),
                          y: bounds.minY - (height - bounds.height) * (1 - min(1, max(0, focus.y))),
                          width: width, height: height)
        }

        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func drawMessage(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let fontSize = max(14, min(22, bounds.width / 34))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: messageColor,
            .paragraphStyle: paragraph,
        ]

        let inset = bounds.insetBy(dx: max(30, bounds.width * 0.08), dy: 30)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.boundingRect(
            with: NSSize(width: inset.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textRect = NSRect(
            x: inset.minX,
            y: bounds.midY - measured.height / 2,
            width: inset.width,
            height: measured.height
        )

        attributed.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private var messageColor: NSColor {
        let color = backdropColor.usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        let base: NSColor = luminance > 0.55 ? .black : .white
        return base.withAlphaComponent(0.72)
    }
}
