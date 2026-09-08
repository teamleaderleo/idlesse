import AppKit
import ImageIO

/// Decode only the first frame at display resolution. Never retain the source file
/// or an unbounded NSImage representation alongside the decoded bitmap.
enum DisplayImageDecoder {
    static let pixelBudget: CGFloat = 16_000_000

    static func load(_ url: URL, target: CGSize, mode: IdlesseScalingMode) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        var w = CGFloat(width.doubleValue), h = CGFloat(height.doubleValue)
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) { swap(&w, &h) }
        let fit = min(target.width / w, target.height / h)
        let fill = max(target.width / w, target.height / h)
        let desired: CGFloat = mode == .actual ? 1 : (mode == .fill ? fill : fit)
        let scale = min(1, max(0, desired), sqrt(pixelBudget / (w * h)), 8192 / max(w, h))
        let edge = max(1, Int(floor(max(w, h) * scale)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Keep original logical geometry, including Actual Size, independently of
        // the bounded backing bitmap. ImageIO retains orientation and color space.
        let image = NSImage(cgImage: bitmap, size: NSSize(width: w, height: h))
        image.cacheMode = .never
        return image
    }
}
