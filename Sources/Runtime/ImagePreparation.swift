import AppKit

/// Serialize expensive decoding across saver displays without blocking AppKit.
actor ImagePreparation {
    static let shared = ImagePreparation()

    func load(_ playable: Playable, target: CGSize, mode: IdlesseScalingMode, scope: URL?) throws -> NSImage {
        try Task.checkCancellation()
        guard playable.kind == .image else { throw SceneError.invalid("The screensaver needs an image.") }
        let accessed = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { scope?.stopAccessingSecurityScopedResource() } }
        guard let image = autoreleasepool(invoking: {
            DisplayImageDecoder.load(playable.assetURL, target: target, mode: mode)
        }) else { throw SceneError.invalid("That image could not be opened.") }
        try Task.checkCancellation()
        return image
    }
}
