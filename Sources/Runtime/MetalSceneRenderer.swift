import AppKit
import AVFoundation
import MetalKit
import CoreVideo

/// Experimental SDR compositor. One drawable per display; groups use bounded offscreen passes.
/// Keep the layer renderer as the default until color and power parity are measured.
final class MetalSceneRenderer: NSObject, SceneRenderer, MTKViewDelegate {
    private final class Input {
        var node: SceneNode
        var texture: MTLTexture?
        var videoTexture: CVMetalTexture?
        var pixelBuffer: CVPixelBuffer?
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var followsClock = false
        var seekInFlight = false
        var transportRevision: UInt64?
        var lastCorrection: Double = -.infinity
        var statusObserver: NSKeyValueObservation?
        init(_ node: SceneNode) { self.node = node }
        func prepareOutputs() {
            // Replicas arrive asynchronously when the looper becomes ready.
            // Outputs are not copied from the template; configure each replica.
            for replica in looper?.loopingPlayerItems ?? player?.items() ?? [] {
                guard !replica.outputs.contains(where: { $0 is AVPlayerItemVideoOutput }) else { continue }
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true])
                output.suppressesPlayerRendering = true
                replica.add(output)
            }
        }
        deinit {
            statusObserver?.invalidate()
            player?.pause()
            looper?.disableLooping()
            player?.removeAllItems()
        }
    }
    /// Completion handlers may outlive renderer teardown. Release wrappers before their cache.
    private final class VideoFrameLifetime {
        let cache: CVMetalTextureCache?
        var wrappers: [CVMetalTexture]
        var buffers: [CVPixelBuffer]
        init(cache: CVMetalTextureCache?, wrappers: [CVMetalTexture], buffers: [CVPixelBuffer]) {
            self.cache = cache; self.wrappers = wrappers; self.buffers = buffers
        }
        deinit {
            wrappers.removeAll()
            buffers.removeAll()
            withExtendedLifetime(cache) {}
        }
    }
    // SIMD4 fields keep Swift/Metal layout identical (16-byte alignment).
    private struct Uniforms {
        var transform: SIMD4<Float> // normalized x/y, scale, rotation radians
        var media: SIMD4<Float> // crop x/y, opacity, gradient flag
        var viewport: SIMD4<Float> // width/height aspect, time, reserved
        var style: SIMD4<Float> // ellipse mask, exposure, saturation, vignette
        var emitter: SIMD4<Float> = .zero // lifetime, speed, size, seed
        var world: SIMD4<Float> = SIMD4(1, 1, 0, 0) // scene-to-display scale and offset
        var motion: SIMD4<Float> = .zero // wind, gravity, count, wrapped emitter time
    }
    private let presentations = PresentedFrameCounter()
    var presentedFrameCount: Int? { presentations.total }
    var gpuTotals: (seconds: Double, frames: Int)? { presentations.gpuTotals }
    let view: NSView
    private let metal: MTKView
    var desktopFrame: CGRect?
    var displayFrame: CGRect?
    private let clock: SceneClock
    private let onError: (String) -> Void
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var inputs: [Input] = []
    private var roots: [SceneNode] = []
    private var sourceScene: SceneDescriptor?
    private let bindingSmoother = SceneBindingSmoother()
    private let targets = GroupTexturePool()
    var intermediateTextureBytes: Int { targets.allocatedBytes }
    var videoTransportPositions: [Double] { inputs.filter { $0.followsClock }.compactMap { $0.player?.currentTime().seconds } }
    private var visibleIDs: Set<UUID> {
        func visit(_ nodes: [SceneNode]) -> [UUID] {
            nodes.filter { $0.visible }.flatMap { [$0.id] + visit($0.children) }
        }
        return Set(visit(roots))
    }
    private var needsFrame = true
    private let gate = DispatchSemaphore(value: 2)
    private(set) var diagnostics = RendererDiagnostics(state: .ready, animated: false, activeResources: 0)

    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, clock: SceneClock,
         onError: @escaping (String) -> Void) throws {
        let authored = playable
        let playable = try playable.evaluated()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SceneError.invalid("Metal is unavailable on this Mac.")
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let spec = MTLRenderPipelineDescriptor()
        spec.vertexFunction = library.makeFunction(name: "sceneQuad")
        spec.fragmentFunction = library.makeFunction(name: "shade")
        let color = spec.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: spec)
        metal = MTKView(frame: bounds, device: device)
        metal.colorPixelFormat = .bgra8Unorm
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metal.preferredFramesPerSecond = 60
        metal.isPaused = true
        metal.enableSetNeedsDisplay = false
        view = metal
        self.clock = clock
        self.queue = queue
        self.onError = onError
        super.init()
        sourceScene = authored
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw SceneError.invalid("Could not create the video texture cache.")
        }
        try SceneBudget.validate(playable.nodes)
        roots = playable.nodes
        for node in playable.allNodes {
            let input = Input(node)
            switch node.content {
            case .image(let url):
                guard let image = DisplayImageDecoder.load(url, target: metal.drawableSize, mode: .fill, pixelLimit: CGFloat(SceneBudget.imagePixels(playable.nodes))),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw SceneError.invalid("That image could not be opened.")
                }
                // Explicit sRGB, premultiplied RGBA upload; release CPU pixels after upload.
                let width = cg.width, height = cg.height
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data else {
                    throw SceneError.invalid("Could not prepare the image texture.")
                }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                    width: width, height: height, mipmapped: false)
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw SceneError.invalid("Could not allocate the image texture.")
                }
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: width * 4)
                input.texture = texture
            case .video(let url):
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 2
                let player = AVQueuePlayer()
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                input.player = player
                input.followsClock = authored.timeline?.videosFollowScene == true
                if input.followsClock {
                    player.actionAtItemEnd = .pause
                    player.insert(item, after: nil)
                    input.prepareOutputs()
                    input.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak input] item, _ in
                        DispatchQueue.main.async { [weak self, weak input] in
                            guard let self, input != nil, self.diagnostics.state != .disposed else { return }
                            if item.status == .failed { onError(item.error?.localizedDescription ?? "Video transport failed.") }
                            if item.status == .readyToPlay { self.needsFrame = true; self.metal.draw() }
                        }
                    }
                } else {
                    let looper = AVPlayerLooper(player: player, templateItem: item)
                    input.looper = looper
                    input.statusObserver = looper.observe(\.status, options: [.initial, .new]) { [weak input] looper, _ in
                        if looper.status == .ready {
                            DispatchQueue.main.async { [weak input] in input?.prepareOutputs() }
                        }
                        if looper.status == .failed {
                            DispatchQueue.main.async { onError(looper.error?.localizedDescription ?? "Video looping failed.") }
                        }
                    }
                }
            case .gradient, .group, .particles: break
            }
            inputs.append(input)
        }
        diagnostics.animated = playable.animated || authored.usesTime || (authored.usesAudio && clock.audioEnabled) || (authored.usesPointer && clock.pointerEnabled)
        diagnostics.activeResources = inputs.count
        // Fail preparation before the host replaces the last working renderer.
        guard let preparedTargets = targets.acquire(device: device, size: metal.drawableSize,
            count: playable.allNodes.filter { $0.kind == .group }.count) else {
            throw SceneError.invalid("Could not prepare the group render targets within the texture budget.")
        }
        targets.recycle(preparedTargets)
        metal.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsFrame = true
        if !diagnostics.animated { view.draw() }
    }
    @discardableResult private func updateVideos() -> Bool {
        guard let cache else { return false }
        var changed = false
        let visible = visibleIDs
        for input in inputs where visible.contains(input.node.id) {
            if input.followsClock { synchronizeVideo(input) }
            guard let player = input.player,
                  let output = player.currentItem?.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first
            else { continue }
            let time = player.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            var wrapper: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper) == kCVReturnSuccess,
                  let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else { continue }
            input.pixelBuffer = buffer
            input.videoTexture = wrapper
            input.texture = texture
            changed = true
        }
        diagnostics.loopCount = inputs.filter { $0.player != nil }.map { $0.looper?.loopCount ?? 0 }.min() ?? 0
        return changed
    }
    private func synchronizeVideo(_ input: Input) {
        guard let player = input.player, let item = player.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let wrapped = clock.time.truncatingRemainder(dividingBy: duration)
        let target = clock.isAtEnd && wrapped < 0.000001 ? max(0, duration - 1.0 / 600) : wrapped
        let rate = diagnostics.state == .running ? clock.effectiveRate : 0
        let now = ProcessInfo.processInfo.systemUptime
        let needsSeek = input.transportRevision != clock.revision ||
            abs(player.currentTime().seconds - target) > (rate == 0 ? 0.002 : 0.12)
        guard !input.seekInFlight else { return }
        if needsSeek && (input.transportRevision != clock.revision || now - input.lastCorrection >= 0.1) {
            input.seekInFlight = true; input.lastCorrection = now
            let revision = clock.revision
            player.pause()
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak input] completed in
                DispatchQueue.main.async { [weak self, weak input] in
                    guard let self, let input, self.diagnostics.state != .disposed else { return }
                    input.seekInFlight = false
                    if completed { input.transportRevision = revision }
                    self.needsFrame = true
                    self.metal.draw()
                }
            }
        } else if !needsSeek {
            player.rate = Float(rate)
        }
    }
    private func encode(_ command: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, size: CGSize) -> Bool {
        guard let pipeline, let device = metal.device else { return false }
        let world = sourceScene?.canvas == .desktopSpan ? desktopFrame : nil
        let sceneAspect = Float((world?.width ?? size.width) / max(1, world?.height ?? size.height))
        let groups = roots.flatMap { $0.descendants }.filter { $0.kind == .group }
        guard let lease = targets.acquire(device: device, size: size, count: groups.count + 3 * roots.flatMap { $0.descendants }.filter { !$0.style.effects.isEmpty }.count) else { return false }
        let groupTextures = Dictionary(uniqueKeysWithValues: zip(groups.map { $0.id }, lease.textures))
        let effected = roots.flatMap { $0.descendants }.filter { !$0.style.effects.isEmpty }
        var effectTargets: [UUID: [MTLTexture]] = [:]
        for (index, node) in effected.enumerated() {
            let start = groups.count + index * 3
            effectTargets[node.id] = Array(lease.textures[start..<(start + 3)])
        }
        var outputs: [UUID: MTLTexture] = [:]
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.node.id, $0) })
        func renderPass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
            let result = MTLRenderPassDescriptor()
            result.colorAttachments[0].texture = texture
            result.colorAttachments[0].loadAction = .clear
            result.colorAttachments[0].storeAction = .store
            result.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            return result
        }
        func configureEmitter(_ emitter: SceneNode.Emitter, uniforms: inout Uniforms) {
            uniforms.media.w = 2
            uniforms.emitter = SIMD4(Float(emitter.lifetime), Float(emitter.speed), Float(emitter.size), Float(emitter.seed))
            uniforms.motion = SIMD4(Float(emitter.wind), Float(emitter.gravity), Float(emitter.count),
                                    Float(clock.time.truncatingRemainder(dividingBy: emitter.lifetime)))
        }
        func effectPass(source: MTLTexture?, original: MTLTexture? = nil, destination: MTLTexture,
                        mode: Float, amount: Float, gradient: Bool = false, emitter: SceneNode.Emitter? = nil, crop: SIMD2<Float> = SIMD2(1, 1)) -> Bool {
            guard let encoder = command.makeRenderCommandEncoder(descriptor: renderPass(destination)) else { return false }
            var u = Uniforms(transform: SIMD4(0, 0, 1, 0), media: SIMD4(crop.x, crop.y, 1, gradient ? 1 : 0),
                viewport: SIMD4(sceneAspect, Float(clock.time.truncatingRemainder(dividingBy: 3600)), mode, amount),
                style: SIMD4(0, 0, 1, 0))
            if let emitter { configureEmitter(emitter, uniforms: &u) }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(original, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: emitter?.count ?? 1)
            encoder.endEncoding()
            return true
        }
        func encodeNodes(_ nodes: [SceneNode], into target: MTLRenderPassDescriptor, root: Bool = false) -> Bool {
            // Children finish their offscreen passes before their parent encoder begins.
            for node in nodes where node.visible && node.kind == .group {
                guard let texture = groupTextures[node.id] else { return false }
                let childPass = MTLRenderPassDescriptor()
                childPass.colorAttachments[0].texture = texture
                childPass.colorAttachments[0].loadAction = .clear
                childPass.colorAttachments[0].storeAction = .store
                childPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard encodeNodes(node.children, into: childPass) else { return false }
            }
            for node in nodes where node.visible && !node.style.effects.isEmpty {
                guard let scratch = effectTargets[node.id] else { return false }
                let source = node.kind == .group ? groupTextures[node.id] : byID[node.id]?.texture
                guard node.kind == .gradient || node.kind == .particles || source != nil else { continue }
                let aspect = sceneAspect
                let mediaAspect = node.kind == .group ? aspect : source.map { Float($0.width) / Float($0.height) } ?? aspect
                guard effectPass(source: source, destination: scratch[0], mode: 0, amount: 0, gradient: node.kind == .gradient, emitter: node.emitter,
                                 crop: SIMD2(min(1, aspect / mediaAspect), min(1, mediaAspect / aspect))) else { return false }
                var current = scratch[0]
                for effect in node.style.effects {
                    let available = scratch.filter { $0 !== current }
                    let amount = Float(effect.amount)
                    switch effect.type {
                    case .blur, .bloom:
                        if amount == 0 { continue }
                        // Radius is relative to scene height, so budget downsampling preserves the visual extent.
                        let radius = (effect.type == .bloom ? Float(12) : amount) / 1080
                        guard effectPass(source: current, destination: available[0], mode: effect.type == .bloom ? 7 : 1, amount: radius),
                              effectPass(source: available[0], destination: available[1], mode: 2, amount: radius) else { return false }
                        if effect.type == .bloom {
                            guard effectPass(source: available[1], original: current, destination: available[0], mode: 3, amount: amount) else { return false }
                            current = available[0]
                        } else { current = available[1] }
                    case .exposure, .saturation, .vignette, .displacement:
                        let mode: Float = effect.type == .displacement ? 8 : effect.type == .exposure ? 4 : effect.type == .saturation ? 5 : 6
                        guard effectPass(source: current, destination: available[0], mode: mode, amount: amount) else { return false }
                        current = available[0]
                    }
                }
                outputs[node.id] = current
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: target) else { return false }
            encoder.setRenderPipelineState(pipeline)
            for node in nodes where node.visible {
                let gradient = node.kind == .gradient && outputs[node.id] == nil
                let texture = outputs[node.id] ?? (node.kind == .group ? groupTextures[node.id] : byID[node.id]?.texture)
                guard gradient || node.kind == .particles || texture != nil else { continue }
                let aspect = sceneAspect
                let mediaAspect = (node.kind == .group || outputs[node.id] != nil) ? aspect : texture.map { Float($0.width) / Float($0.height) } ?? aspect
                let t = node.transform
                var u = Uniforms(transform: SIMD4(Float(t.x ?? 0), Float(t.y ?? 0), Float(t.scale ?? 1), Float((t.rotation ?? 0) * .pi / 180)),
                    media: SIMD4(min(1, aspect / mediaAspect), min(1, mediaAspect / aspect), Float(node.opacity), gradient ? 1 : 0),
                    viewport: SIMD4(aspect, Float(clock.time.truncatingRemainder(dividingBy: 3600)), 0, 0),
                    style: SIMD4(node.style.mask == .ellipse ? 1 : 0, Float(node.style.exposure), Float(node.style.saturation), Float(node.style.vignette)))
                if outputs[node.id] == nil, let emitter = node.emitter { configureEmitter(emitter, uniforms: &u) }
                if root, let world, let display = displayFrame {
                    u.world = SIMD4(Float(world.width / display.width), Float(world.height / display.height),
                        Float((world.midX - display.midX) * 2 / display.width),
                        Float((world.midY - display.midY) * 2 / display.height))
                }
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: outputs[node.id] == nil ? node.emitter?.count ?? 1 : 1)
            }
            encoder.endEncoding()
            return true
        }
        guard encodeNodes(roots, into: pass, root: true) else { targets.recycle(lease); return false }
        // Hold both the Core Video buffers and this frame's group targets through completion.
        let videoLifetime = VideoFrameLifetime(cache: cache, wrappers: inputs.compactMap { $0.videoTexture },
                                               buffers: inputs.compactMap { $0.pixelBuffer })
        let targets = self.targets
        command.addCompletedHandler { _ in
            withExtendedLifetime(videoLifetime) {}
            targets.recycle(lease)
        }
        return true
    }
    func updateScene(_ scene: SceneDescriptor) -> Bool {
        let authored = scene
        guard (sourceScene?.timeline?.videosFollowScene == true) == (scene.timeline?.videosFollowScene == true) else { return false }
        guard let scene = try? scene.evaluated(signals: currentSignals()) else { return false }
        guard diagnostics.state != .disposed,
              let order = sceneResourceOrder(from: inputs.map { $0.node }, to: scene.allNodes) else { return false }
        guard (try? SceneBudget.validate(scene.nodes)) != nil else { return false }
        roots = scene.nodes
        sourceScene = authored
        bindingSmoother.reset()
        inputs = order.map { inputs[$0] }
        for (input, node) in zip(inputs, scene.allNodes) { input.node = node }
        diagnostics.animated = scene.animated || authored.usesTime || (authored.usesAudio && clock.audioEnabled) || (authored.usesPointer && clock.pointerEnabled)
        setPaused(diagnostics.state != .running)
        metal.draw()
        return true
    }
    func draw(in view: MTKView) {
        guard diagnostics.state != .disposed, let queue, gate.wait(timeout: .now()) == .success else { return }
        if diagnostics.state == .running { updateSignals(currentSignals()) }
        let changed = updateVideos()
        needsFrame = needsFrame || changed
        guard needsFrame || roots.flatMap({ $0.descendants }).contains(where: { visibleIDs.contains($0.id) && $0.hasAnimatedEffects }) || inputs.contains(where: { visibleIDs.contains($0.node.id) && ($0.node.kind == .gradient || $0.node.kind == .particles) }) else {
            gate.signal(); return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), encode(command, pass, size: view.drawableSize) else {
            gate.signal(); return
        }
        let gate = self.gate
        let gpuMetrics = presentations
        command.addCompletedHandler { [weak self] command in
            gate.signal()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsFrame, !self.diagnostics.animated, self.diagnostics.state != .disposed else { return }
                self.metal.draw()
            }
            if command.status == .completed { gpuMetrics.recordGPU(start: command.gpuStartTime, end: command.gpuEndTime) }
            if command.status == .error {
                DispatchQueue.main.async { [weak self] in self?.onError("The compositor could not render a frame.") }
            }
        }
        let presentations = self.presentations
        drawable.addPresentedHandler { drawable in
            presentations.record(presentedTime: drawable.presentedTime)
        }
        command.present(drawable)
        command.commit()
        needsFrame = false
        diagnostics.frameCount += 1
        updateDrawScheduling()
    }
    func refreshSceneTime() {
        guard diagnostics.state != .disposed else { return }
        updateSignals(currentSignals())
        needsFrame = true
        updateDrawScheduling()
        metal.draw()
    }
    private func updateDrawScheduling() {
        // A completed once scene has no moving clock. Independent videos,
        // pointer input and smoothing may still change its final composition.
        let independentVideo = inputs.contains { visibleIDs.contains($0.node.id) && $0.node.kind == .video && !$0.followsClock }
        let reactive = (sourceScene?.usesAudio == true && clock.audioEnabled) || sourceScene?.usesSmoothing == true || (sourceScene?.usesPointer == true && clock.pointerEnabled)
        let finished = clock.isAtEnd && !independentVideo && !reactive
        metal.isPaused = diagnostics.state != .running || !diagnostics.animated || finished
    }
    private func currentSignals() -> SceneSignals {
        var signals = SceneSignals(time: clock.time)
        if sourceScene?.usesAudio == true, clock.audioEnabled { signals.audio = clock.audioLevels() }
        if sourceScene?.usesPointer == true, clock.pointerEnabled, let window = metal.window {
            if sourceScene?.canvas == .desktopSpan, let world = desktopFrame {
                let point = NSEvent.mouseLocation
                signals.pointerX = min(1, max(-1, Double((point.x - world.minX) / max(1, world.width) * 2 - 1)))
                signals.pointerY = min(1, max(-1, Double((point.y - world.minY) / max(1, world.height) * 2 - 1)))
                return signals
            }
            let point = metal.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            signals.pointerX = min(1, max(-1, Double(point.x / max(1, metal.bounds.width) * 2 - 1)))
            let y = Double(point.y / max(1, metal.bounds.height) * 2 - 1)
            signals.pointerY = min(1, max(-1, metal.isFlipped ? -y : y))
        }
        return signals
    }
    private func updateSignals(_ signals: SceneSignals) {
        guard let sourceScene, sourceScene.usesSignals else { return }
        bindingSmoother.beginFrame(time: ProcessInfo.processInfo.systemUptime, revision: clock.revision)
        guard let evaluated = try? sourceScene.evaluated(signals: signals, validating: false, smooth: { [bindingSmoother] target, value, duration in
            bindingSmoother.sample(target: target, value: value, duration: duration)
        }) else { return }
        let changed = sourceScene.bindings.contains { binding in
            (try? binding.target.value(in: roots)) != (try? binding.target.value(in: evaluated.nodes))
        }
        guard changed else { return }
        roots = evaluated.nodes
        for (input, node) in zip(inputs, evaluated.allNodes) { input.node = node }
        needsFrame = true
    }
    static func smokeTestGroupTextureBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SceneError.invalid("Metal unavailable") }
        let pool = GroupTexturePool()
        let size = CGSize(width: 7680, height: 4320)
        guard let first = pool.acquire(device: device, size: size, count: 4),
              let second = pool.acquire(device: device, size: size, count: 4) else { throw SceneError.invalid("Group budget allocation failed") }
        precondition(pool.allocatedBytes <= SceneBudget.intermediateTextureBytes)
        precondition(pool.acquire(device: device, size: size, count: 4) == nil, "In-flight targets must not be reused or exceed the cap")
        pool.recycle(first)
        guard let resized = pool.acquire(device: device, size: CGSize(width: 1920, height: 1080), count: 4) else { throw SceneError.invalid("Group resize failed") }
        precondition(pool.allocatedBytes <= SceneBudget.intermediateTextureBytes)
        pool.dispose()
        pool.recycle(second)
        pool.recycle(resized)
        precondition(pool.allocatedBytes == 0)
        let effectPool = GroupTexturePool()
        let count = SceneBudget.maxGroups + 3 * SceneBudget.maxNodes
        guard let a = effectPool.acquire(device: device, size: size, count: count),
              let b = effectPool.acquire(device: device, size: size, count: count) else {
            throw SceneError.invalid("Effect budget allocation failed")
        }
        precondition(effectPool.allocatedBytes <= SceneBudget.intermediateTextureBytes)
        effectPool.dispose()
        effectPool.recycle(a); effectPool.recycle(b)
        precondition(effectPool.allocatedBytes == 0)
    }
    /// Small GPU readback for tests; never used by the display loop.
    func renderProbe(signals: SceneSignals? = nil, dimension: Int = 32) throws -> [UInt8] {
        try renderFrame(signals: signals, width: dimension, height: dimension)
    }
    func renderFrame(signals: SceneSignals? = nil, width: Int, height: Int, sampleVideo: Bool = true) throws -> [UInt8] {
        guard (32...3840).contains(width), (32...2160).contains(height) else { throw SceneError.invalid("Frame size must be 32–3840 by 32–2160 pixels.") }
        if let signals { updateSignals(signals) }
        guard let device = metal.device, let queue else { throw SceneError.invalid("Renderer disposed.") }
        if sampleVideo { updateVideos() }
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        spec.storageMode = .shared
        spec.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: spec), let command = queue.makeCommandBuffer() else {
            throw SceneError.invalid("Probe allocation failed.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard encode(command, pass, size: CGSize(width: width, height: height)) else { throw SceneError.invalid("Probe encoding failed.") }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw SceneError.invalid("Probe GPU execution failed.") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return bytes
    }
    func setPreferredFrameRate(_ rate: Int?) {
        guard diagnostics.state != .disposed else { return }
        metal.preferredFramesPerSecond = rate ?? 60
    }
    func setPaused(_ paused: Bool) {
        bindingSmoother.reset()
        guard diagnostics.state != .disposed else { return }
        diagnostics.state = paused ? .paused : .running
        needsFrame = true
        let visible = visibleIDs
        inputs.forEach { input in
            if input.followsClock || paused || !visible.contains(input.node.id) { input.player?.pause() } else { input.player?.play() }
        }
        updateDrawScheduling()
        if !diagnostics.animated || inputs.contains(where: { $0.followsClock }) { metal.draw() }
    }
    func releaseResources() {
        metal.isPaused = true
        metal.delegate = nil
        inputs.removeAll()
        roots.removeAll()
        sourceScene = nil
        bindingSmoother.reset()
        targets.dispose()
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        cache = nil
        pipeline = nil
        queue = nil
        metal.releaseDrawables()
        diagnostics.state = .disposed
        diagnostics.activeResources = 0
    }
    deinit { releaseResources() }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4 transform; float4 media; float4 viewport; float4 style; float4 emitter; float4 world; float4 motion; };
    struct V { float4 position [[position]]; float2 uv; float fade; float2 canvasUV; };
    uint randomBits(uint value) {
        value ^= value >> 16; value *= 0x7feb352du; value ^= value >> 15;
        value *= 0x846ca68bu; return value ^ (value >> 16);
    }
    float randomUnit(uint value) { return float(randomBits(value) & 0x00ffffffu) / 16777216.0; }
    vertex V sceneQuad(uint id [[vertex_id]], uint instance [[instance_id]], constant U &u [[buffer(0)]]) {
        float2 p = float2(id & 1, id >> 1) * 2.0 - 1.0;
        float2 local = p;
        float fade = 1;
        if (u.media.w > 1.5) {
            uint seed = uint(u.emitter.w) ^ (instance * 747796405u);
            float age = fmod(u.motion.w + float(instance) / u.motion.z * u.emitter.x, u.emitter.x);
            float phase = age / u.emitter.x;
            fade = smoothstep(0.0, 0.12, phase) * (1.0 - smoothstep(0.75, 1.0, phase));
            float2 origin = float2(randomUnit(seed) * 1.8 - 0.9, randomUnit(seed + 1u) * 1.8 - 0.9);
            float2 velocity = float2(u.motion.x, u.emitter.y * (0.5 + randomUnit(seed + 2u)));
            local = origin + velocity * age + float2(0, 0.5 * u.motion.y * age * age);
            local += float2(p.x / u.viewport.x, p.y) * u.emitter.z * (0.6 + randomUnit(seed + 3u));
        }
        float2 q = local * float2(u.viewport.x, 1.0) * u.transform.z;
        float c = cos(u.transform.w), s = sin(u.transform.w);
        q = float2(c*q.x - s*q.y, s*q.x + c*q.y) / float2(u.viewport.x, 1.0);
        q += u.transform.xy * 2.0;
        q = q * u.world.xy + u.world.zw;
        return {float4(q, 0, 1), float2((p.x+1)*0.5, (1-p.y)*0.5), fade, float2(local.x * 0.5 + 0.5, 0.5 - local.y * 0.5)};
    }
    float4 styled(float4 pixel, float2 uv, constant U &u) {
        if (u.style.x == 0.0 && u.style.y == 0.0 && u.style.z == 1.0 && u.style.w == 0.0) return pixel * u.media.z;
        float3 color = pixel.rgb / max(pixel.a, 0.00001);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = clamp(mix(float3(luma), color, u.style.z) * exp2(u.style.y), 0.0, 1.0);
        float2 radial = uv * 2.0 - 1.0;
        color *= 1.0 - u.style.w * smoothstep(0.15, 1.5, dot(radial, radial));
        float coverage = 1.0;
        if (u.style.x > 0.5) {
            float distance = length(uv * 2.0 - 1.0);
            float edge = max(fwidth(distance), 0.0001);
            coverage = 1.0 - smoothstep(1.0 - edge, 1.0, distance);
        }
        return float4(color * pixel.a, pixel.a) * (coverage * u.media.z);
    }
    fragment float4 shade(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]], texture2d<float> original [[texture(1)]]) {

        if (u.media.w > 1.5) {
            float r = length(v.uv * 2 - 1);
            float alpha = (1.0 - smoothstep(0.05, 1.0, r)) * v.fade;
            return styled(float4(float3(1.0, 0.72, 0.22) * alpha, alpha), v.canvasUV, u);
        }
        constexpr sampler effectSample(filter::linear, address::clamp_to_edge);
        int mode = int(u.viewport.z);
        float amount = u.viewport.w;
        if (mode == 1 || mode == 2 || mode == 7) {
            float2 step = mode == 2 ? float2(0, amount / 4) : float2(amount / (4 * u.viewport.x), 0);
            float4 result = 0;
            float total = 0;
            for (int i = -4; i <= 4; ++i) {
                float weight = exp(-float(i*i) / 8.0);
                float4 pixel = image.sample(effectSample, v.uv + float(i) * step);
                if (mode == 7) pixel.rgb *= smoothstep(0.55, 0.85, max(pixel.r, max(pixel.g, pixel.b)));
                result += pixel * weight;
                total += weight;
            }
            return result / total;
        }
        if (mode == 3) {
            float4 base = original.sample(effectSample, v.uv);
            float4 glow = image.sample(effectSample, v.uv);
            float a = max(base.a, min(1.0, max(glow.r, max(glow.g, glow.b)) * amount));
            return float4(min(float3(a), base.rgb + glow.rgb * amount), a);
        }
        if (mode == 8) {
            float phase = u.viewport.y * (6.28318530718 / 8.0);
            float2 offset = float2(sin(v.uv.y * 18.0 + phase) / u.viewport.x,
                                   sin(v.uv.x * 15.0 - phase)) * amount;
            return image.sample(effectSample, v.uv + offset);
        }
        if (mode >= 4 && mode <= 6) {
            float4 pixel = image.sample(effectSample, v.uv);
            float3 color = pixel.rgb / max(pixel.a, 0.00001);
            if (mode == 4) color *= exp2(amount);
            if (mode == 5) color = mix(float3(dot(color, float3(0.2126,0.7152,0.0722))), color, amount);
            if (mode == 6) { float2 radial = v.uv * 2 - 1; color *= 1 - amount * smoothstep(0.15, 1.5, dot(radial, radial)); }
            return float4(clamp(color, 0.0, 1.0) * pixel.a, pixel.a);
        }

        if (u.media.w > 0.5) {
            float2 uv = float2(v.uv.x, 1.0-v.uv.y);
            float t = u.viewport.y;
            float wave = 0.5 + 0.5 * sin(uv.x*5.0 + sin(uv.y*3.0+t*0.2)+t*0.15);
            float3 high = mix(float3(0.1,0.6,0.5), float3(0.5,0.15,0.65), wave);
            return styled(float4(mix(float3(0.025,0.035,0.12),high,smoothstep(0.0,1.2,wave*(1.0-uv.y*0.5))),1), v.uv, u);
        }
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        return styled(image.sample(sample, (v.uv-0.5)*u.media.xy+0.5), v.uv, u);
    }
    """
}

/// Leases are exclusive until GPU completion. Cached and in-flight textures both
/// count toward the cap, including old sizes retained during a window resize.
private final class GroupTexturePool {
    struct Lease {
        let textures: [MTLTexture]
        let bytes: Int
        let width: Int
        let height: Int
    }
    private let lock = NSLock()
    private var free: [Lease] = []
    private var bytes = 0
    private var disposed = false
    var allocatedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
    func acquire(device: MTLDevice, size: CGSize, count: Int) -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard !disposed else { return nil }
        if count == 0 { return Lease(textures: [], bytes: 0, width: 0, height: 0) }
        guard var extent = SceneBudget.groupTargetSize(width: size.width, height: size.height, count: count) else { return nil }
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: extent.width, height: extent.height, mipmapped: false)
        spec.storageMode = .private
        spec.usage = [.renderTarget, .shaderRead]
        // Tile layout and alignment are device-specific; pixel bytes alone can
        // underestimate the actual allocation, especially near the budget edge.
        var estimate = device.heapTextureSizeAndAlign(descriptor: spec).size
        while estimate > SceneBudget.intermediateTextureBytes / (2 * count) {
            guard extent.width > 1 || extent.height > 1 else { return nil }
            extent = (max(1, Int(Double(extent.width) * 0.95)), max(1, Int(Double(extent.height) * 0.95)))
            spec.width = extent.width
            spec.height = extent.height
            estimate = device.heapTextureSizeAndAlign(descriptor: spec).size
        }
        if let index = free.firstIndex(where: { $0.width == extent.width && $0.height == extent.height && $0.textures.count == count }) {
            return free.remove(at: index)
        }
        // Drop only idle targets; a previous frame may still be using its lease.
        bytes -= free.reduce(0) { $0 + $1.bytes }
        free.removeAll()
        guard estimate <= (SceneBudget.intermediateTextureBytes - bytes) / count else { return nil }
        var textures: [MTLTexture] = []
        var allocated = 0
        for _ in 0..<count {
            guard let texture = device.makeTexture(descriptor: spec) else { return nil }
            allocated += max(texture.allocatedSize, estimate)
            guard allocated <= SceneBudget.intermediateTextureBytes - bytes else { return nil }
            textures.append(texture)
        }
        bytes += allocated
        return Lease(textures: textures, bytes: allocated, width: extent.width, height: extent.height)
    }
    func recycle(_ lease: Lease) {
        guard !lease.textures.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if disposed { bytes -= lease.bytes } else { free.append(lease) }
    }
    func dispose() {
        lock.lock(); defer { lock.unlock() }
        disposed = true
        bytes -= free.reduce(0) { $0 + $1.bytes }
        free.removeAll()
    }
}
