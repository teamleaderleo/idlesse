import AppKit
import AVFoundation
import MetalKit
import CoreVideo

/// Experimental SDR compositor. One drawable and one render pass per display.
/// Keep the layer renderer as the default until color and power parity are measured.
final class MetalSceneRenderer: NSObject, SceneRenderer, MTKViewDelegate {
    private final class Input {
        let node: SceneNode
        var texture: MTLTexture?
        var videoTexture: CVMetalTexture?
        var pixelBuffer: CVPixelBuffer?
        var output: AVPlayerItemVideoOutput?
        var player: AVPlayer?
        var endObserver: NSObjectProtocol?
        var statusObserver: NSKeyValueObservation?
        var loops = 0
        var paused = true
        init(_ node: SceneNode) { self.node = node }
        deinit {
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            player?.pause()
        }
    }
    // SIMD4 fields keep Swift/Metal layout identical (16-byte alignment).
    private struct Uniforms {
        var transform: SIMD4<Float> // normalized x/y, scale, rotation radians
        var media: SIMD4<Float> // crop x/y, opacity, gradient flag
        var viewport: SIMD4<Float> // width/height aspect, time, reserved
    }
    let view: NSView
    private let metal: MTKView
    private let clock: SceneClock
    private let onError: (String) -> Void
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var inputs: [Input] = []
    private let gate = DispatchSemaphore(value: 2)
    private(set) var diagnostics = RendererDiagnostics(state: .ready, animated: false, activeResources: 0)

    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, clock: SceneClock,
         onError: @escaping (String) -> Void) throws {
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
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw SceneError.invalid("Could not create the video texture cache.")
        }
        for node in playable.nodes {
            let input = Input(node)
            switch node.content {
            case .image(let url):
                guard let image = DisplayImageDecoder.load(url, target: metal.drawableSize, mode: .fill),
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
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true])
                output.suppressesPlayerRendering = true
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 2
                item.add(output)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                input.player = player
                input.output = output
                input.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                    object: item, queue: .main) { [weak input] _ in
                    guard let input else { return }
                    input.loops += 1
                    input.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak input] finished in
                        DispatchQueue.main.async {
                            if finished, let input, !input.paused { input.player?.play() }
                        }
                    }
                }
                input.statusObserver = item.observe(\.status, options: [.new]) { item, _ in
                    if item.status == .failed {
                        DispatchQueue.main.async { onError(item.error?.localizedDescription ?? "Video decoding failed.") }
                    }
                }
            case .gradient: break
            }
            inputs.append(input)
        }
        diagnostics.animated = playable.animated
        diagnostics.activeResources = inputs.count
        metal.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if !diagnostics.animated { view.draw() }
    }
    private func updateVideos() {
        guard let cache else { return }
        for input in inputs {
            guard let output = input.output, let player = input.player else { continue }
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
        }
        diagnostics.loopCount = inputs.filter { $0.player != nil }.map { $0.loops }.min() ?? 0
    }
    private func encode(_ command: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, size: CGSize) -> Bool {
        guard let pipeline, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        for input in inputs {
            let gradient = input.node.kind == .gradient
            guard gradient || input.texture != nil else { continue }
            let aspect = Float(size.width / max(1, size.height))
            let mediaAspect = input.texture.map { Float($0.width) / Float($0.height) } ?? aspect
            let t = input.node.transform
            var u = Uniforms(transform: SIMD4(Float(t.x ?? 0), Float(t.y ?? 0), Float(t.scale ?? 1), Float((t.rotation ?? 0) * .pi / 180)),
                media: SIMD4(min(1, aspect / mediaAspect), min(1, mediaAspect / aspect), Float(input.node.opacity), gradient ? 1 : 0),
                viewport: SIMD4(aspect, Float(clock.time.truncatingRemainder(dividingBy: 3600)), 0, 0))
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(input.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        // Core Video wrappers AND buffers must outlive asynchronous GPU access.
        let wrappers = inputs.compactMap { $0.videoTexture }
        let buffers = inputs.compactMap { $0.pixelBuffer }
        command.addCompletedHandler { _ in
            withExtendedLifetime(wrappers) {}
            withExtendedLifetime(buffers) {}
        }
        return true
    }
    func draw(in view: MTKView) {
        guard diagnostics.state != .disposed, let queue, gate.wait(timeout: .now()) == .success else { return }
        updateVideos()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), encode(command, pass, size: view.drawableSize) else {
            gate.signal(); return
        }
        let gate = self.gate
        command.addCompletedHandler { [weak self] command in
            gate.signal()
            if command.status == .error {
                DispatchQueue.main.async { [weak self] in self?.onError("The compositor could not render a frame.") }
            }
        }
        command.present(drawable)
        command.commit()
        diagnostics.frameCount += 1
    }
    /// Small GPU readback for tests; never used by the display loop.
    func renderProbe() throws -> [UInt8] {
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
    func setPaused(_ paused: Bool) {
        guard diagnostics.state != .disposed else { return }
        diagnostics.state = paused ? .paused : .running
        inputs.forEach { input in
            input.paused = paused
            if paused { input.player?.pause() } else { input.player?.play() }
        }
        metal.isPaused = paused || !diagnostics.animated
        if !diagnostics.animated { metal.draw() }
    }
    func releaseResources() {
        metal.isPaused = true
        metal.delegate = nil
        inputs.removeAll()
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
    struct U { float4 transform; float4 media; float4 viewport; };
    struct V { float4 position [[position]]; float2 uv; };
    vertex V sceneQuad(uint id [[vertex_id]], constant U &u [[buffer(0)]]) {
        float2 p = float2(id & 1, id >> 1) * 2.0 - 1.0;
        float2 q = p * float2(u.viewport.x, 1.0) * u.transform.z;
        float c = cos(u.transform.w), s = sin(u.transform.w);
        q = float2(c*q.x - s*q.y, s*q.x + c*q.y) / float2(u.viewport.x, 1.0);
        q += u.transform.xy * 2.0;
        return {float4(q, 0, 1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
    }
    fragment float4 shade(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
        if (u.media.w > 0.5) {
            float2 uv = float2(v.uv.x, 1.0-v.uv.y);
            float t = u.viewport.y;
            float wave = 0.5 + 0.5 * sin(uv.x*5.0 + sin(uv.y*3.0+t*0.2)+t*0.15);
            float3 high = mix(float3(0.1,0.6,0.5), float3(0.5,0.15,0.65), wave);
            return float4(mix(float3(0.025,0.035,0.12),high,smoothstep(0.0,1.2,wave*(1.0-uv.y*0.5))),1)*u.media.z;
        }
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        return image.sample(sample, (v.uv-0.5)*u.media.xy+0.5)*u.media.z;
    }
    """
}
