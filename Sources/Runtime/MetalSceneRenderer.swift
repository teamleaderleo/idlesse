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
        var statusObserver: NSKeyValueObservation?
        init(_ node: SceneNode) { self.node = node }
        func prepareOutputs() {
            // Replicas arrive asynchronously when the looper becomes ready.
            // Outputs are not copied from the template; configure each replica.
            for replica in looper?.loopingPlayerItems ?? [] {
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
    // SIMD4 fields keep Swift/Metal layout identical (16-byte alignment).
    private struct Uniforms {
        var transform: SIMD4<Float> // normalized x/y, scale, rotation radians
        var media: SIMD4<Float> // crop x/y, opacity, gradient flag
        var viewport: SIMD4<Float> // width/height aspect, time, reserved
        var style: SIMD4<Float> // ellipse mask, exposure, saturation, vignette
    }
    private let presentations = PresentedFrameCounter()
    var presentedFrameCount: Int? { presentations.total }
    var gpuTotals: (seconds: Double, frames: Int)? { presentations.gpuTotals }
    let view: NSView
    private let metal: MTKView
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
                let looper = AVPlayerLooper(player: player, templateItem: item)
                input.player = player
                input.looper = looper
                input.statusObserver = looper.observe(\.status, options: [.initial, .new]) { [weak input] looper, _ in
                    if looper.status == .ready {
                        DispatchQueue.main.async { [weak input] in input?.prepareOutputs() }
                    }
                    if looper.status == .failed {
                        DispatchQueue.main.async { onError(looper.error?.localizedDescription ?? "Video looping failed.") }
                    }
                }
            case .gradient, .group: break
            }
            inputs.append(input)
        }
        diagnostics.animated = playable.animated || authored.usesTime || (authored.usesPointer && clock.pointerEnabled)
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
    private func encode(_ command: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, size: CGSize) -> Bool {
        guard let pipeline, let device = metal.device else { return false }
        let groups = roots.flatMap { $0.descendants }.filter { $0.kind == .group }
        guard let lease = targets.acquire(device: device, size: size, count: groups.count) else { return false }
        let groupTextures = Dictionary(uniqueKeysWithValues: zip(groups.map { $0.id }, lease.textures))
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.node.id, $0) })
        func encodeNodes(_ nodes: [SceneNode], into target: MTLRenderPassDescriptor) -> Bool {
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
            guard let encoder = command.makeRenderCommandEncoder(descriptor: target) else { return false }
            encoder.setRenderPipelineState(pipeline)
            for node in nodes where node.visible {
                let gradient = node.kind == .gradient
                let texture = node.kind == .group ? groupTextures[node.id] : byID[node.id]?.texture
                guard gradient || texture != nil else { continue }
                let aspect = Float(size.width / max(1, size.height))
                let mediaAspect = node.kind == .group ? aspect : texture.map { Float($0.width) / Float($0.height) } ?? aspect
                let t = node.transform
                var u = Uniforms(transform: SIMD4(Float(t.x ?? 0), Float(t.y ?? 0), Float(t.scale ?? 1), Float((t.rotation ?? 0) * .pi / 180)),
                    media: SIMD4(min(1, aspect / mediaAspect), min(1, mediaAspect / aspect), Float(node.opacity), gradient ? 1 : 0),
                    viewport: SIMD4(aspect, Float(clock.time.truncatingRemainder(dividingBy: 3600)), 0, 0),
                    style: SIMD4(node.style.mask == .ellipse ? 1 : 0, Float(node.style.exposure), Float(node.style.saturation), Float(node.style.vignette)))
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
            return true
        }
        guard encodeNodes(roots, into: pass) else { targets.recycle(lease); return false }
        // Hold both the Core Video buffers and this frame's group targets through completion.
        let wrappers = inputs.compactMap { $0.videoTexture }
        let buffers = inputs.compactMap { $0.pixelBuffer }
        let targets = self.targets
        command.addCompletedHandler { _ in
            withExtendedLifetime(wrappers) {}
            withExtendedLifetime(buffers) {}
            targets.recycle(lease)
        }
        return true
    }
    func updateScene(_ scene: SceneDescriptor) -> Bool {
        let authored = scene
        guard let scene = try? scene.evaluated(signals: currentSignals()) else { return false }
        guard diagnostics.state != .disposed,
              let order = sceneResourceOrder(from: inputs.map { $0.node }, to: scene.allNodes) else { return false }
        guard (try? SceneBudget.validate(scene.nodes)) != nil else { return false }
        roots = scene.nodes
        sourceScene = authored
        bindingSmoother.reset()
        inputs = order.map { inputs[$0] }
        for (input, node) in zip(inputs, scene.allNodes) { input.node = node }
        diagnostics.animated = scene.animated || authored.usesTime || (authored.usesPointer && clock.pointerEnabled)
        setPaused(diagnostics.state != .running)
        metal.draw()
        return true
    }
    func draw(in view: MTKView) {
        guard diagnostics.state != .disposed, let queue, gate.wait(timeout: .now()) == .success else { return }
        if diagnostics.state == .running { updateSignals(currentSignals()) }
        let changed = updateVideos()
        needsFrame = needsFrame || changed
        guard needsFrame || inputs.contains(where: { visibleIDs.contains($0.node.id) && $0.node.kind == .gradient }) else {
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
    }
    func refreshSceneTime() {
        guard diagnostics.state != .disposed else { return }
        updateSignals(currentSignals())
        needsFrame = true
        metal.draw()
    }
    private func currentSignals() -> SceneSignals {
        var signals = SceneSignals(time: clock.time)
        if sourceScene?.usesPointer == true, clock.pointerEnabled, let window = metal.window {
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
    }
    /// Small GPU readback for tests; never used by the display loop.
    func renderProbe(signals: SceneSignals? = nil) throws -> [UInt8] {
        if let signals { updateSignals(signals) }
        guard let device = metal.device, let queue else { throw SceneError.invalid("Renderer disposed.") }
        updateVideos()
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
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
        guard encode(command, pass, size: CGSize(width: 32, height: 32)) else { throw SceneError.invalid("Probe encoding failed.") }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw SceneError.invalid("Probe GPU execution failed.") }
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 128,
            from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0) }
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
            if paused || !visible.contains(input.node.id) { input.player?.pause() } else { input.player?.play() }
        }
        metal.isPaused = paused || !diagnostics.animated
        if !diagnostics.animated { metal.draw() }
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
    struct U { float4 transform; float4 media; float4 viewport; float4 style; };
    struct V { float4 position [[position]]; float2 uv; };
    vertex V sceneQuad(uint id [[vertex_id]], constant U &u [[buffer(0)]]) {
        float2 p = float2(id & 1, id >> 1) * 2.0 - 1.0;
        float2 q = p * float2(u.viewport.x, 1.0) * u.transform.z;
        float c = cos(u.transform.w), s = sin(u.transform.w);
        q = float2(c*q.x - s*q.y, s*q.x + c*q.y) / float2(u.viewport.x, 1.0);
        q += u.transform.xy * 2.0;
        return {float4(q, 0, 1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
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
    fragment float4 shade(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
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
