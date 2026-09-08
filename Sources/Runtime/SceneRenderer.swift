import AppKit
import AVFoundation

protocol SceneRenderer: AnyObject {
    var view: NSView { get }
    var player: AVQueuePlayer? { get }
    var completedLoops: Int { get }
    func setPaused(_ paused: Bool)
    func releaseResources()
}

extension SceneRenderer {
    var player: AVQueuePlayer? { nil }
    var completedLoops: Int { 0 }
}

private final class VideoWallpaperView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

final class StaticImageRenderer: SceneRenderer {
    let view: NSView
    init(playable: Playable, bounds: NSRect, scale: CGFloat) throws {
        let size = CGSize(width: bounds.width * scale,
                          height: bounds.height * scale)
        guard let image = DisplayImageDecoder.load(playable.assetURL, target: size, mode: .fill) else {
            throw SceneError.invalid("That image could not be opened.")
        }
        let canvas = ImageCanvasView(frame: bounds)
        canvas.scalingMode = .fill
        canvas.currentImage = image
        view = canvas
    }
    func setPaused(_ paused: Bool) {}
    func releaseResources() { (view as? ImageCanvasView)?.currentImage = nil }
}

final class VideoRenderer: SceneRenderer {
    let view: NSView
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observation: NSKeyValueObservation?
    var completedLoops: Int { looper?.loopCount ?? 0 }
    init(playable: Playable, bounds: NSRect, onError: @escaping (String) -> Void) {
        let view = VideoWallpaperView(frame: bounds)
        view.wantsLayer = true
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: playable.assetURL)
        item.preferredForwardBufferDuration = 2
        let loop = AVPlayerLooper(player: queue, templateItem: item)
        (view.layer as? AVPlayerLayer)?.player = queue
        (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
        self.view = view
        player = queue
        looper = loop
        observation = loop.observe(\.status, options: [.new]) { loop, _ in
            if loop.status == .failed {
                DispatchQueue.main.async { onError(loop.error?.localizedDescription ?? "Video playback failed.") }
            }
        }
    }
    func setPaused(_ paused: Bool) {
        if paused { player?.pause() } else { player?.play() }
    }
    func releaseResources() {
        observation = nil
        player?.pause()
        looper?.disableLooping()
        (view.layer as? AVPlayerLayer)?.player = nil
        player?.removeAllItems()
        looper = nil
        player = nil
    }
    deinit { releaseResources() }
}
