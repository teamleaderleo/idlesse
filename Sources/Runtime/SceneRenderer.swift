import AppKit
import AVFoundation

enum SceneFrameRate: Int, CaseIterable {
    case automatic = 0, matchDisplay = -1, fps30 = 30, fps60 = 60, fps120 = 120, fps160 = 160
    static let changed = Notification.Name("IdlesseSceneFrameRateChanged")
    static var selected: SceneFrameRate {
        get { SceneFrameRate(rawValue: UserDefaults.standard.integer(forKey: "sceneFrameRate")) ?? .automatic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "sceneFrameRate")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    var title: String {
        switch self {
        case .automatic: return "Frame Rate: Auto"
        case .matchDisplay: return "Match Display"
        default: return "\(rawValue) fps"
        }
    }
    func requested(maximum: Int) -> Int? {
        let maximum = maximum > 0 ? maximum : 60
        switch self {
        case .automatic: return nil
        case .matchDisplay: return maximum
        default: return min(rawValue, maximum)
        }
    }
}

/// Constant-space accounting; callbacks may arrive off the main thread.
final class PresentedFrameCounter {
    private let lock = NSLock()
    private var count = 0
    private var gpuSeconds = 0.0
    private var completed = 0
    func recordGPU(start: TimeInterval, end: TimeInterval) {
        guard start > 0, end >= start, end.isFinite else { return }
        lock.lock()
        gpuSeconds += end - start
        completed += 1
        lock.unlock()
    }
    var gpuTotals: (seconds: Double, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (gpuSeconds, completed)
    }
    func record(presentedTime: TimeInterval) {
        guard presentedTime > 0, presentedTime.isFinite else { return }
        lock.lock()
        count += 1
        lock.unlock()
    }
    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct PresentationRateSample {
    private var previous: (count: Int, time: TimeInterval)?
    mutating func sample(count: Int, time: TimeInterval) -> Double? {
        defer { previous = (count, time) }
        guard let previous, time > previous.time, count >= previous.count else { return nil }
        return Double(count - previous.count) / (time - previous.time)
    }
}

struct RendererDiagnostics {
    enum State { case ready, running, paused, disposed }
    var state: State
    var animated: Bool
    var activeResources: Int
    var loopCount: Int = 0
    var frameCount: Int = 0
    var audioMuted: Bool = true
    var allowsDisplaySleep: Bool = true
}

protocol SceneRenderer: AnyObject {
    var view: NSView { get }
    var diagnostics: RendererDiagnostics { get }
    var presentedFrameCount: Int? { get }
    var gpuTotals: (seconds: Double, frames: Int)? { get }
    func setPaused(_ paused: Bool)
    func setPreferredFrameRate(_ rate: Int?)
    func releaseResources()
}

extension SceneRenderer {
    var presentedFrameCount: Int? { nil }
    var gpuTotals: (seconds: Double, frames: Int)? { nil }
    // AVPlayerLayer follows source playback; static images do not need a redraw loop.
    func setPreferredFrameRate(_ rate: Int?) {}
}

private final class VideoWallpaperView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

final class StaticImageRenderer: SceneRenderer {
    let view: NSView
    private(set) var diagnostics = RendererDiagnostics(state: .ready, animated: false, activeResources: 1)
    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat) throws {
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let url = playable.assetURL,
              let image = DisplayImageDecoder.load(url, target: size, mode: .fill) else {
            throw SceneError.invalid("That image could not be opened.")
        }
        let canvas = ImageCanvasView(frame: bounds)
        canvas.scalingMode = .fill
        canvas.currentImage = image
        view = canvas
    }
    func setPaused(_ paused: Bool) {
        guard diagnostics.state != .disposed else { return }
        diagnostics.state = paused ? .paused : .running
    }
    func releaseResources() {
        (view as? ImageCanvasView)?.currentImage = nil
        diagnostics.state = .disposed
        diagnostics.activeResources = 0
    }
}

final class VideoRenderer: SceneRenderer {
    let view: NSView
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observation: NSKeyValueObservation?
    private var state: RendererDiagnostics.State = .ready
    var diagnostics: RendererDiagnostics {
        RendererDiagnostics(state: state, animated: true, activeResources: player == nil ? 0 : 1,
            loopCount: looper?.loopCount ?? 0, audioMuted: player?.isMuted ?? true,
            allowsDisplaySleep: !(player?.preventsDisplaySleepDuringVideoPlayback ?? false))
    }
    init(url: URL, bounds: NSRect, onError: @escaping (String) -> Void) {
        let view = VideoWallpaperView(frame: bounds)
        view.wantsLayer = true
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
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
        guard state != .disposed else { return }
        state = paused ? .paused : .running
        if paused { player?.pause() } else { player?.play() }
    }
    func releaseResources() {
        state = .disposed
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

/// Array order is back to front. Normal alpha composition only.
final class LayeredSceneRenderer: SceneRenderer {
    let view: NSView
    private var children: [SceneRenderer] = []
    private var state: RendererDiagnostics.State = .ready
    var gpuTotals: (seconds: Double, frames: Int)? {
        children.count == 1 ? children.first?.gpuTotals : nil
    }
    var presentedFrameCount: Int? {
        // Separate layer surfaces cannot be reported as one scene presentation.
        children.count == 1 ? children.first?.presentedFrameCount : nil
    }
    var diagnostics: RendererDiagnostics {
        let snapshots = children.map { $0.diagnostics }
        return RendererDiagnostics(state: state, animated: snapshots.contains { $0.animated },
            activeResources: snapshots.reduce(0) { $0 + $1.activeResources },
            loopCount: snapshots.filter { $0.animated }.map { $0.loopCount }.min() ?? 0,
            frameCount: snapshots.reduce(0) { $0 + $1.frameCount },
            audioMuted: snapshots.allSatisfy { $0.audioMuted },
            allowsDisplaySleep: snapshots.allSatisfy { $0.allowsDisplaySleep })
    }
    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, clock: SceneClock,
         onError: @escaping (String) -> Void) throws {
        view = NSView(frame: bounds)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        do {
            for node in playable.nodes {
                let child: SceneRenderer
                switch node.content {
                case .image(let url):
                    child = try StaticImageRenderer(playable: SceneDescriptor(title: playable.title, assetURL: url, kind: .image), bounds: bounds, scale: scale)
                    (child.view as? ImageCanvasView)?.backdropColor = .clear
                case .video(let url): child = VideoRenderer(url: url, bounds: bounds, onError: onError)
                case .gradient: child = try GradientRenderer(bounds: bounds, clock: clock, onError: onError)
                }
                child.view.alphaValue = node.opacity
                let container = NSView(frame: bounds)
                container.wantsLayer = true
                container.addSubview(child.view)
                view.addSubview(container)
                let t = node.transform
                let factor = t.scale ?? 1
                // Normalized translation; rotation is degrees around the node center.
                var transform = CATransform3DMakeTranslation((t.x ?? 0) * bounds.width,
                                                            (t.y ?? 0) * bounds.height, 0)
                transform = CATransform3DRotate(transform, (t.rotation ?? 0) * .pi / 180, 0, 0, 1)
                transform = CATransform3DScale(transform, factor, factor, 1)
                container.layer?.transform = transform
                children.append(child)
            }
        } catch { releaseResources(); throw error }
    }
    func setPreferredFrameRate(_ rate: Int?) {
        children.forEach { $0.setPreferredFrameRate(rate) }
    }
    func setPaused(_ paused: Bool) {
        guard state != .disposed else { return }
        state = paused ? .paused : .running
        children.forEach { $0.setPaused(paused) }
    }
    func releaseResources() {
        state = .disposed
        children.forEach { $0.releaseResources() }
        children.removeAll()
        view.subviews.forEach { $0.removeFromSuperview() }
    }
    deinit { releaseResources() }
}
