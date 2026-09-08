import AppKit
import MetalKit

/// A built-in Metal node; no community shader execution or permissions required.
final class GradientRenderer: NSObject, SceneRenderer, MTKViewDelegate {
    let view: NSView
    private let metal: MTKView
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let clock: SceneClock
    private let onError: (String) -> Void
    private let inFlight = DispatchSemaphore(value: 2)
    private(set) var diagnostics = RendererDiagnostics(state: .ready, animated: true, activeResources: 1)

    init(bounds: NSRect, clock: SceneClock, onError: @escaping (String) -> Void) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SceneError.invalid("Metal is unavailable on this Mac.")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex fullScreen(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return {float4(p * 2.0 - 1.0, 0, 1), p};
        }
        fragment float4 aurora(Vertex v [[stage_in]], constant float &time [[buffer(0)]]) {
            float wave = 0.5 + 0.5 * sin(v.uv.x * 5.0 + sin(v.uv.y * 3.0 + time * 0.2) + time * 0.15);
            float3 low = float3(0.025, 0.035, 0.12);
            float3 high = mix(float3(0.1, 0.6, 0.5), float3(0.5, 0.15, 0.65), wave);
            return float4(mix(low, high, smoothstep(0.0, 1.2, wave * (1.0 - v.uv.y * 0.5))), 1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreen")
        descriptor.fragmentFunction = library.makeFunction(name: "aurora")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        metal = MTKView(frame: bounds, device: device)
        metal.colorPixelFormat = .bgra8Unorm
        metal.preferredFramesPerSecond = 30
        metal.isPaused = true
        metal.enableSetNeedsDisplay = false
        view = metal
        self.queue = queue
        self.clock = clock
        self.onError = onError
        super.init()
        metal.delegate = self
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard diagnostics.state != .disposed, let pipeline, let queue,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        guard encode(command: command, pass: pass, pipeline: pipeline) else { inFlight.signal(); return }
        let gate = inFlight
        command.addCompletedHandler { [weak self] buffer in
            gate.signal()
            if buffer.status == .error {
                DispatchQueue.main.async { [weak self] in self?.onError("The Metal scene could not render a frame.") }
            }
        }
        command.present(drawable)
        command.commit()
        diagnostics.frameCount += 1
    }
    private func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                        pipeline: MTLRenderPipelineState) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var time = Float(clock.time.truncatingRemainder(dividingBy: 3600))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// Bounded offscreen readback for verifying the actual production GPU pipeline.
    func renderProbe() throws -> [UInt8] {
        guard let device = metal.device, let queue, let pipeline else {
            throw SceneError.invalid("The renderer has been disposed.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 32, height: 32, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw SceneError.invalid("Could not allocate the render probe.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard encode(command: command, pass: pass, pipeline: pipeline) else {
            throw SceneError.invalid("Could not encode the render probe.")
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw SceneError.invalid("Metal rendering failed.") }
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: 32 * 4,
                from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
        }
        return bytes
    }

    func setPaused(_ paused: Bool) {
        guard diagnostics.state != .disposed else { return }
        diagnostics.state = paused ? .paused : .running
        metal.isPaused = paused
    }
    func releaseResources() {
        metal.isPaused = true
        metal.delegate = nil
        metal.releaseDrawables()
        queue = nil
        pipeline = nil
        diagnostics.state = .disposed
        diagnostics.activeResources = 0
    }
    deinit { releaseResources() }
}
