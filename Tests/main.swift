import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("large.png")
autoreleasepool {
    let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000))
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}
for (label, target, mode, maxEdge) in [
    ("preview", CGSize(width: 320, height: 180), IdlesseScalingMode.fit, 320),
    ("retina", CGSize(width: 3840, height: 2160), .fit, 3840),
    ("fill", CGSize(width: 3840, height: 2160), .fill, 3840),
    ("budget", CGSize(width: 16000, height: 16000), .fill, 8192),
    ("actual", CGSize(width: 320, height: 180), .actual, 8192),
] {
    autoreleasepool {
        let image = DisplayImageDecoder.load(file, target: target, mode: mode)!
        let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(max(bitmap.width, bitmap.height) <= maxEdge)
        precondition(bitmap.width * bitmap.height <= 16_000_000)
        precondition(image.size == NSSize(width: 6000, height: 4000))
        precondition(bitmap.alphaInfo != .none)
        print("\(label): \(bitmap.width)x\(bitmap.height), \(bitmap.bytesPerRow * bitmap.height) decoded bytes")
    }
}
precondition(DisplayImageDecoder.load(folder.appendingPathComponent("missing"), target: .zero, mode: .fit) == nil)
let bounded = DisplayImageDecoder.load(file, target: CGSize(width: 16000, height: 16000), mode: .fill, pixelLimit: 2_000_000)!
let boundedBitmap = bounded.cgImage(forProposedRect: nil, context: nil, hints: nil)!
precondition(boundedBitmap.width * boundedBitmap.height <= 2_000_000)
precondition(DisplayImageDecoder.load(file, target: .zero, mode: .fill, pixelLimit: .nan) == nil)
print("Decoder checks passed")

// Check fit/fill geometry and color at representative opaque interior pixels.
let sourceContext = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sourceContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
sourceContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
sourceContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
sourceContext.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
let colorImage = NSImage(cgImage: sourceContext.makeImage()!, size: NSSize(width: 40, height: 20))
colorImage.cacheMode = .never
for mode in [IdlesseScalingMode.fit, .fill, .actual] {
    let surface = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    canvas.currentImage = colorImage
    canvas.scalingMode = mode
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: surface)
    canvas.draw(canvas.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let left = surface.colorAt(x: 30, y: 40)!.usingColorSpace(.sRGB)!
    let right = surface.colorAt(x: 50, y: 40)!.usingColorSpace(.sRGB)!
    precondition(left.redComponent > 0.95 && left.blueComponent < 0.05)
    precondition(right.blueComponent > 0.95 && right.redComponent < 0.05)
    if mode != .fill {
        let background = surface.colorAt(x: 40, y: 5)!.usingColorSpace(.sRGB)!
        precondition(background.redComponent < 0.05 && background.blueComponent < 0.05)
    }
}
print("Canvas geometry and color checks passed")

// Focal fill uses top-left unit coordinates; fit and absent focus stay centered.
let focusedCanvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
focusedCanvas.scalingMode = .fill
let wideImage = NSImage(size: NSSize(width: 200, height: 100))
precondition(focusedCanvas.destinationRect(for: wideImage) == NSRect(x: -50, y: 0, width: 200, height: 100))
focusedCanvas.fillFocus = CGPoint(x: 0, y: 0)
precondition(focusedCanvas.destinationRect(for: wideImage).origin == .zero)
focusedCanvas.fillFocus = CGPoint(x: 2, y: -1)
precondition(focusedCanvas.destinationRect(for: wideImage).origin == CGPoint(x: -100, y: 0))
let tallImage = NSImage(size: NSSize(width: 100, height: 200))
precondition(focusedCanvas.destinationRect(for: tallImage).origin == CGPoint(x: 0, y: -100))
focusedCanvas.fillFocus = CGPoint(x: 0, y: 1)
precondition(focusedCanvas.destinationRect(for: tallImage).origin == .zero)
focusedCanvas.scalingMode = .fit
precondition(focusedCanvas.destinationRect(for: wideImage) == NSRect(x: 0, y: 25, width: 100, height: 50))
print("Focal image geometry passed")
