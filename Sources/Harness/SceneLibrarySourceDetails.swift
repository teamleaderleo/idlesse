import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    static func sourceDetails(_ url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov"].contains(ext) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return "" }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displayed = size.applying(transform)
            let fps = try await track.load(.nominalFrameRate)
            return " · \(Int(abs(displayed.width))) × \(Int(abs(displayed.height))) · \(String(format: "%g", fps)) fps"
        }
        guard ext != "idlesse" else { return "" }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "" }
            return " · \(width) × \(height)"
        }.value
    }
}
