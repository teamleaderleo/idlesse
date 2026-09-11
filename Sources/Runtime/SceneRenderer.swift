import AppKit
import AVFoundation
import Metal
import CoreVideo
import IOKit.ps

enum PowerManagement {
    private static var powerRunLoopSource: CFRunLoopSource?

    static func startMonitoring() {
        guard powerRunLoopSource == nil else { return }
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: SceneFrameRate.changed, object: nil)
            }
        }, nil)?.takeRetainedValue() {
            powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    static var isBatteryPowered: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else { return false }
        return type == "Battery Power"
    }

    static var isLowPowerOrBatteryThrottled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled ||
            (SceneFrameRate.throttleOnBattery && isBatteryPowered)
    }
}

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
    static var throttleOnBattery: Bool {
        get { UserDefaults.standard.object(forKey: "sceneFrameRateThrottleOnBattery") == nil ? false : UserDefaults.standard.bool(forKey: "sceneFrameRateThrottleOnBattery") }
        set {
            UserDefaults.standard.set(newValue, forKey: "sceneFrameRateThrottleOnBattery")
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
        PowerManagement.startMonitoring()
        if PowerManagement.isLowPowerOrBatteryThrottled {
            return min(30, maximum)
        }
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
    /// Opt-in audible video. Default implementation ignores it (stills, Metal
    /// composites without a player); players override. Muted by default.
    func setMuted(_ muted: Bool)
    func releaseResources()
    func updateScene(_ scene: SceneDescriptor) -> Bool
    func refreshSceneTime()
}

extension SceneRenderer {
    func refreshSceneTime() { view.needsDisplay = true }
    func setMuted(_ muted: Bool) {}
    func updateScene(_ scene: SceneDescriptor) -> Bool { false }
    var presentedFrameCount: Int? { nil }
    var gpuTotals: (seconds: Double, frames: Int)? { nil }
    // AVPlayerLayer follows source playback; static images do not need a redraw loop.
    func setPreferredFrameRate(_ rate: Int?) {}
}

private final class VideoWallpaperView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

/// Native animated stills (GIF/APNG/animated WebP): frames stay on disk and are
/// decoded one at a time on frame ticks, so a loop costs one frame of RAM.
/// Anything single-frame (or undecodable) throws and the caller falls back to
/// StaticImageRenderer. Metal scenes show the first frame; animation lives in
/// the Standard compositor.
final class AnimatedImageRenderer: SceneRenderer {
    let view: NSView
    private let canvas = ImageCanvasView()
    private let source: CGImageSource
    private let count: Int
    private let delays: [Double]
    private var index = 0
    private var loops = 0
    private var frames = 0
    private var timer: Timer?
    private var state: RendererDiagnostics.State = .ready

    var diagnostics: RendererDiagnostics {
        RendererDiagnostics(state: state, animated: true, activeResources: 1,
            loopCount: loops, frameCount: frames)
    }

    init(url: URL, bounds: NSRect) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 1 else {
            throw SceneError.invalid("Not an animated image.")
        }
        let count = CGImageSourceGetCount(source)
        guard count <= 600 else { throw SceneError.invalid("That animation has too many frames.") }
        var delays: [Double] = []
        for i in 0..<count {
            delays.append(Self.delay(source: source, index: i))
        }
        self.source = source
        self.count = count
        self.delays = delays
        view = canvas
        canvas.frame = bounds
        canvas.scalingMode = .fill
        canvas.backdropColor = .clear
        showFrame(0)
    }

    private static func delay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return min(10, max(0.02, delay))
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let delay = png["DelayTime" as CFString] as? Double {
            return min(10, max(0.02, delay))
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
           let duration = (webp["Duration" as CFString] as? Double).map({ $0 / 1000 }) {
            return min(10, max(0.02, duration))
        }
        return 0.1
    }

    private func showFrame(_ i: Int) {
        guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { return }
        canvas.currentImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        frames += 1
    }

    private func arm() {
        timer?.invalidate()
        guard state == .running else { return }
        let timer = Timer(timeInterval: delays[index], repeats: false) { [weak self] _ in
            guard let self, self.state == .running else { return }
            self.index += 1
            if self.index >= self.count { self.index = 0; self.loops += 1 }
            self.showFrame(self.index)
            self.arm()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPaused(_ paused: Bool) {
        guard state != .disposed else { return }
        state = paused ? .paused : .running
        if paused { timer?.invalidate(); timer = nil } else { arm() }
    }
    func setPreferredFrameRate(_ rate: Int?) {}
    func releaseResources() {
        state = .disposed
        timer?.invalidate(); timer = nil
        canvas.currentImage = nil
    }
    deinit { releaseResources() }
}

/// Static single-frame fallback; see AnimatedImageRenderer above for loops.
final class StaticImageRenderer: SceneRenderer {
    let view: NSView
    private(set) var diagnostics = RendererDiagnostics(state: .ready, animated: false, activeResources: 1)
    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, pixelLimit: CGFloat = DisplayImageDecoder.pixelBudget) throws {
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let url = playable.assetURL,
              let image = DisplayImageDecoder.load(url, target: size, mode: .fill, pixelLimit: pixelLimit) else {
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

/// Manages a single shared video playback engine across multiple display surfaces.
/// This prevents multiple hardware decoders (VTDecoderXPCService) from duplicating
/// uncompressed framebuffers when the same scene or video is displayed across monitors.
final class SharedVideoHub {
    final class TrackedVideo {
        let nodeID: UUID
        let url: URL
        let player: AVQueuePlayer
        var looper: AVPlayerLooper?
        var statusObserver: NSKeyValueObservation?
        var followsClock: Bool = false
        var seekInFlight: Bool = false
        var lastCorrection: Double = -.infinity
        var transportRevision: UInt64?

        struct CachedFrame {
            let buffer: CVPixelBuffer
            let wrapper: CVMetalTexture?
            let texture: MTLTexture?
            let time: CMTime
        }
        var recentFrames: [CachedFrame] = []
        var latestTexture: MTLTexture?
        var latestWrapper: CVMetalTexture?
        var latestBuffer: CVPixelBuffer?

        init(nodeID: UUID, url: URL, player: AVQueuePlayer) {
            self.nodeID = nodeID
            self.url = url
            self.player = player
        }

        func prepareOutputs() {
            for replica in looper?.loopingPlayerItems ?? player.items() {
                replica.preferredForwardBufferDuration = 0.5
                guard !replica.outputs.contains(where: { $0 is AVPlayerItemVideoOutput }) else { continue }
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ])
                output.suppressesPlayerRendering = false
                replica.add(output)
            }
        }

        deinit {
            statusObserver?.invalidate()
            player.pause()
            looper?.disableLooping()
            player.removeAllItems()
            recentFrames.removeAll()
            latestTexture = nil
            latestWrapper = nil
            latestBuffer = nil
        }
    }

    struct SampledFrame {
        let texture: MTLTexture?
        let wrapper: CVMetalTexture?
        let buffer: CVPixelBuffer?
    }

    private let lock = NSLock()
    private var videos: [UUID: TrackedVideo] = [:]
    private var cache: CVMetalTextureCache?
    private var isClosed = false

    var primaryPlayer: AVQueuePlayer? {
        lock.lock(); defer { lock.unlock() }
        return videos.values.first?.player
    }

    var loopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return videos.values.compactMap { $0.looper?.loopCount }.min() ?? 0
    }

    init(scene: SceneDescriptor, clock: SceneClock, onError: @escaping (String) -> Void) {
        if let device = MTLCreateSystemDefaultDevice() {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        }
        for node in scene.allNodes {
            guard case .video(let url) = node.content else { continue }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 0.5
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let tracked = TrackedVideo(nodeID: node.id, url: url, player: player)
            tracked.followsClock = scene.timeline?.videosFollowScene == true
            if tracked.followsClock {
                player.actionAtItemEnd = .pause
                player.insert(item, after: nil)
                tracked.prepareOutputs()
                tracked.statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                    if item.status == .failed {
                        DispatchQueue.main.async { onError(item.error?.localizedDescription ?? "Video transport failed.") }
                    }
                }
            } else {
                let looper = AVPlayerLooper(player: player, templateItem: item)
                tracked.looper = looper
                tracked.statusObserver = looper.observe(\.status, options: [.initial, .new]) { [weak tracked] looper, _ in
                    if looper.status == .ready {
                        DispatchQueue.main.async { tracked?.prepareOutputs() }
                    }
                    if looper.status == .failed {
                        DispatchQueue.main.async { onError(looper.error?.localizedDescription ?? "Video looping failed.") }
                    }
                }
            }
            videos[node.id] = tracked
        }
    }

    func player(for nodeID: UUID) -> AVQueuePlayer? {
        lock.lock(); defer { lock.unlock() }
        return videos[nodeID]?.player
    }

    func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        for video in videos.values {
            if video.followsClock || paused {
                video.player.pause()
            } else {
                video.player.play()
            }
        }
    }
    func setMuted(_ muted: Bool) {
        lock.lock(); defer { lock.unlock() }
        for video in videos.values {
            video.player.isMuted = muted
            if !muted { video.player.volume = 1 }
        }
    }

    func sample(nodeID: UUID, clock: SceneClock, isRunning: Bool) -> SampledFrame? {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, let tracked = videos[nodeID] else { return nil }
        if tracked.followsClock {
            synchronizeVideo(tracked, clock: clock, isRunning: isRunning)
        }
        guard let output = tracked.player.currentItem?.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first else {
            return SampledFrame(texture: tracked.latestTexture, wrapper: tracked.latestWrapper, buffer: tracked.latestBuffer)
        }
        let time = tracked.player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var wrapper: CVMetalTexture?
            var texture: MTLTexture?
            if let cache {
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                if CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper) == kCVReturnSuccess,
                   let wrapper {
                    texture = CVMetalTextureGetTexture(wrapper)
                }
            }
            tracked.latestBuffer = buffer
            tracked.latestWrapper = wrapper
            tracked.latestTexture = texture
            tracked.recentFrames.append(TrackedVideo.CachedFrame(buffer: buffer, wrapper: wrapper, texture: texture, time: time))
            if tracked.recentFrames.count > 2 {
                tracked.recentFrames.removeFirst()
            }
            return SampledFrame(texture: texture, wrapper: wrapper, buffer: buffer)
        } else {
            return SampledFrame(texture: tracked.latestTexture, wrapper: tracked.latestWrapper, buffer: tracked.latestBuffer)
        }
    }

    private func synchronizeVideo(_ tracked: TrackedVideo, clock: SceneClock, isRunning: Bool) {
        guard let item = tracked.player.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let wrapped = clock.time.truncatingRemainder(dividingBy: duration)
        let target = clock.isAtEnd && wrapped < 0.000001 ? max(0, duration - 1.0 / 600) : wrapped
        let rate = isRunning ? clock.effectiveRate : 0
        let now = ProcessInfo.processInfo.systemUptime
        let needsSeek = tracked.transportRevision != clock.revision ||
            abs(tracked.player.currentTime().seconds - target) > (rate == 0 ? 0.002 : 0.12)
        guard !tracked.seekInFlight else { return }
        if needsSeek && (tracked.transportRevision != clock.revision || now - tracked.lastCorrection >= 0.1) {
            tracked.seekInFlight = true
            tracked.lastCorrection = now
            let revision = clock.revision
            tracked.player.pause()
            tracked.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak tracked] completed in
                DispatchQueue.main.async { [weak tracked] in
                    guard let tracked else { return }
                    tracked.seekInFlight = false
                    if completed { tracked.transportRevision = revision }
                }
            }
        } else if !needsSeek {
            tracked.player.rate = Float(rate)
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        for video in videos.values {
            video.statusObserver?.invalidate()
            video.player.pause()
            video.looper?.disableLooping()
            video.player.removeAllItems()
        }
        videos.removeAll()
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    deinit { close() }
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
        item.preferredForwardBufferDuration = 0.5
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
    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        if !muted { player?.volume = 1 }
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
    private var nodes: [SceneNode] = []
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
        return RendererDiagnostics(state: state, animated: zip(snapshots, nodes).contains { $0.0.animated && $0.1.visible },
            activeResources: snapshots.reduce(0) { $0 + $1.activeResources },
            loopCount: snapshots.filter { $0.animated }.map { $0.loopCount }.min() ?? 0,
            frameCount: snapshots.reduce(0) { $0 + $1.frameCount },
            audioMuted: snapshots.allSatisfy { $0.audioMuted },
            allowsDisplaySleep: snapshots.allSatisfy { $0.allowsDisplaySleep })
    }
    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, clock: SceneClock,
         onError: @escaping (String) -> Void, imagePixels: Int? = nil) throws {
        guard !playable.requiresMetal else { throw SceneError.invalid("Masks and color effects require the Metal renderer.") }
        let playable = try playable.evaluated()
        try SceneBudget.validate(playable.nodes)
        let imagePixels = imagePixels ?? SceneBudget.imagePixels(playable.nodes)
        nodes = playable.nodes
        view = NSView(frame: bounds)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        do {
            for node in playable.nodes {
                let child: SceneRenderer
                switch node.content {
                case .image(let url):
                    if let animated = try? AnimatedImageRenderer(url: url, bounds: bounds) {
                        child = animated
                    } else {
                        child = try StaticImageRenderer(playable: SceneDescriptor(title: playable.title, assetURL: url, kind: .image), bounds: bounds, scale: scale, pixelLimit: CGFloat(imagePixels))
                    }
                    (child.view as? ImageCanvasView)?.backdropColor = .clear
                case .video(let url): child = VideoRenderer(url: url, bounds: bounds, onError: onError)
                case .particles, .text, .shape: throw SceneError.invalid("This creative layer requires Metal.")
                case .gradient: child = try GradientRenderer(bounds: bounds, clock: clock, onError: onError)
                case .group(let nodes):
                    child = try LayeredSceneRenderer(playable: SceneDescriptor(title: node.displayName, nodes: nodes),
                        bounds: bounds, scale: scale, clock: clock, onError: onError, imagePixels: imagePixels)
                    child.view.layer?.allowsGroupOpacity = true
                }
                child.view.alphaValue = node.visible ? node.opacity : 0
                let container = NSView(frame: bounds)
                container.wantsLayer = true
                container.addSubview(child.view)
                view.addSubview(container)
                let t = node.transform
                let factor = t.scale ?? 1
                // Normalized translation; rotation is degrees around the node center.
                var transform = CATransform3DMakeTranslation((0.5 + (t.x ?? 0)) * bounds.width,
                                                            (0.5 + (t.y ?? 0)) * bounds.height, 0)
                transform = CATransform3DRotate(transform, (t.rotation ?? 0) * .pi / 180, 0, 0, 1)
                transform = CATransform3DScale(transform, factor, factor, 1)
                transform = CATransform3DTranslate(transform, -bounds.width / 2, -bounds.height / 2, 0)
                // AppKit owns the backing layer transform and may reset it on attachment.
                container.layer?.sublayerTransform = transform
                children.append(child)
            }
        } catch { releaseResources(); throw error }
    }
    func updateScene(_ scene: SceneDescriptor) -> Bool {
        guard !scene.requiresMetal, let scene = try? scene.evaluated() else { return false }
        guard state != .disposed, !scene.requiresMetal, let order = sceneResourceOrder(from: nodes, to: scene.nodes) else { return false }
        guard (try? SceneBudget.validate(scene.nodes)) != nil else { return false }
        // The recursive resource check above preflights every subtree before mutation.
        for (index, node) in scene.nodes.enumerated() where node.kind == .group {
            guard children[order[index]].updateScene(SceneDescriptor(title: node.displayName, nodes: node.children)) else { return false }
        }
        let containers = view.subviews
        let reordered = order.map { containers[$0] }
        children = order.map { children[$0] }
        nodes = scene.nodes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.subviews = reordered
        let bounds = view.bounds
        for (index, node) in nodes.enumerated() {
            children[index].view.alphaValue = node.visible ? node.opacity : 0
            let t = node.transform
            var matrix = CATransform3DMakeTranslation((0.5 + (t.x ?? 0)) * bounds.width,
                                                       (0.5 + (t.y ?? 0)) * bounds.height, 0)
            matrix = CATransform3DRotate(matrix, (t.rotation ?? 0) * .pi / 180, 0, 0, 1)
            matrix = CATransform3DScale(matrix, t.scale ?? 1, t.scale ?? 1, 1)
            matrix = CATransform3DTranslate(matrix, -bounds.width / 2, -bounds.height / 2, 0)
            reordered[index].layer?.sublayerTransform = matrix
        }
        CATransaction.commit()
        for (child, node) in zip(children, nodes) { child.setPaused(state != .running || !node.visible) }
        return true
    }
    func setPreferredFrameRate(_ rate: Int?) {
        children.forEach { $0.setPreferredFrameRate(rate) }
    }
    func setPaused(_ paused: Bool) {
        guard state != .disposed else { return }
        state = paused ? .paused : .running
        for (child, node) in zip(children, nodes) { child.setPaused(paused || !node.visible) }
    }
    func setMuted(_ muted: Bool) {
        children.forEach { $0.setMuted(muted) }
    }
    func releaseResources() {
        state = .disposed
        children.forEach { $0.releaseResources() }
        children.removeAll()
        view.subviews.forEach { $0.removeFromSuperview() }
    }
    deinit { releaseResources() }
}
