import AppKit

final class ImageCanvasView: NSView {
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

    var message: String? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
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

    private func destinationRect(for image: NSImage) -> NSRect {
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
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
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
}
