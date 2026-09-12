import Foundation
import Metal
import Darwin

private struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct EffectUniforms {
    var time: Float
    var amount: Float
    var padding = SIMD2<Float>.zero
}

private struct ProbeResult {
    let width: Int
    let height: Int
    let inputTextures: Int
    let intermediateTextures: Int
    let intermediateBytes: Int
    let budgetBytes: Int
    let measuredFrames: Int
    let gpuFrames: Int
    let averageGPUMilliseconds: Double?
    let averageWallMilliseconds: Double

    var line: String {
        let gpu = averageGPUMilliseconds.map { String(format: "%.3f", $0) } ?? "unavailable"
        return "CUSTOM_SHADER_EFFECT_PROBE width=\(width) height=\(height) input_textures=\(inputTextures) intermediate_textures=\(intermediateTextures) intermediate_bytes=\(intermediateBytes) budget_bytes=\(budgetBytes) measured_frames=\(measuredFrames) gpu_frames=\(gpuFrames) avg_gpu_ms=\(gpu) avg_wall_ms=\(String(format: "%.3f", averageWallMilliseconds))"
    }
}

/// Phase-2 format gate: one existing input texture enters one custom fragment pass and
/// exactly one new render target leaves it. Keep this probe independent of scene decoding
/// so format semantics are added only after the real Metal cost is known.
private enum CustomShaderEffectProbe {
    static let width = 1_920
    static let height = 1_080
    static let warmupFrames = 4
    static let measuredFrames = 24
    static let intermediateBudgetBytes = 128 * 1024 * 1024 // SceneBudget.intermediateTextureBytes.

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct V { float4 position [[position]]; float2 uv; };
    struct U { float time; float amount; float2 padding; };

    vertex V effectProbeVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0,  1.0), float2(1.0,  1.0)
        };
        const float2 uvs[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        return { float4(positions[id], 0.0, 1.0), uvs[id] };
    }

    fragment float4 effectProbeFragment(V in [[stage_in]],
                                         texture2d<float> source [[texture(0)]],
                                         constant U &u [[buffer(0)]]) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float2 offset = float2(sin(in.uv.y * 19.0 + u.time) / 240.0,
                               cos(in.uv.x * 17.0 - u.time) / 320.0);
        float4 pixel = source.sample(sample, in.uv + offset);
        float3 processed = mix(pixel.rgb, 1.0 - pixel.bgr, u.amount);
        return float4(processed, pixel.a);
    }
    """

    static func run() throws -> ProbeResult {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeError(message: "Metal device unavailable; this runner cannot provide the required real GPU smoke measurement.")
        }
        guard let queue = device.makeCommandQueue() else {
            throw ProbeError(message: "Could not create Metal command queue.")
        }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: metalSource, options: nil) }
        catch { throw ProbeError(message: "Probe shader compilation failed: \(error.localizedDescription)") }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "effectProbeVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "effectProbeFragment")
        pipelineDescriptor.colorAttachments[0]?.pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        do { pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor) }
        catch { throw ProbeError(message: "Probe pipeline creation failed: \(error.localizedDescription)") }

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        guard let source = device.makeTexture(descriptor: sourceDescriptor) else {
            throw ProbeError(message: "Could not allocate the existing-input probe texture.")
        }

        var sourcePixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                sourcePixels[offset] = UInt8((x * 3 + y) & 0xff)
                sourcePixels[offset + 1] = UInt8((x + y * 5) & 0xff)
                sourcePixels[offset + 2] = UInt8((x * 7 + y * 11) & 0xff)
                sourcePixels[offset + 3] = 255
            }
        }
        sourcePixels.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
        }

        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        destinationDescriptor.storageMode = .private
        destinationDescriptor.usage = [.renderTarget, .shaderRead]
        guard let destination = device.makeTexture(descriptor: destinationDescriptor) else {
            throw ProbeError(message: "Could not allocate the single custom-effect intermediate texture.")
        }
        let estimatedBytes = device.heapTextureSizeAndAlign(descriptor: destinationDescriptor).size
        let intermediateBytes = max(destination.allocatedSize, estimatedBytes)
        guard intermediateBytes > 0, intermediateBytes <= intermediateBudgetBytes else {
            throw ProbeError(message: "One custom-effect intermediate uses \(intermediateBytes) bytes, exceeding the \(intermediateBudgetBytes)-byte scene budget.")
        }

        let readbackBytes = width * height * 4
        guard let readback = device.makeBuffer(length: readbackBytes, options: .storageModeShared) else {
            throw ProbeError(message: "Could not allocate validation readback buffer.")
        }

        var gpuSeconds = 0.0
        var gpuFrames = 0
        var wallSeconds = 0.0

        func render(frame: Int, measure: Bool, readResult: Bool) throws {
            guard let command = queue.makeCommandBuffer() else { throw ProbeError(message: "Could not allocate command buffer.") }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw ProbeError(message: "Could not create custom-effect render encoder.")
            }
            var uniforms = EffectUniforms(time: Float(frame) / 60.0, amount: 0.55)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            if readResult {
                guard let blit = command.makeBlitCommandEncoder() else {
                    throw ProbeError(message: "Could not create validation blit encoder.")
                }
                blit.copy(from: destination, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: readback, destinationOffset: 0, destinationBytesPerRow: width * 4,
                    destinationBytesPerImage: readbackBytes)
                blit.endEncoding()
            }

            let start = CFAbsoluteTimeGetCurrent()
            command.commit()
            command.waitUntilCompleted()
            let end = CFAbsoluteTimeGetCurrent()
            guard command.status == .completed else {
                throw ProbeError(message: "Custom-effect GPU execution failed: \(command.error?.localizedDescription ?? "unknown Metal error")")
            }
            if measure {
                wallSeconds += end - start
                if command.gpuStartTime > 0, command.gpuEndTime >= command.gpuStartTime {
                    gpuSeconds += command.gpuEndTime - command.gpuStartTime
                    gpuFrames += 1
                }
            }
        }

        for frame in 0..<warmupFrames { try render(frame: frame, measure: false, readResult: false) }
        for frame in 0..<measuredFrames {
            try render(frame: frame + warmupFrames, measure: true, readResult: frame == measuredFrames - 1)
        }

        let center = ((height / 2) * width + width / 2) * 4
        let output = readback.contents().assumingMemoryBound(to: UInt8.self)
        let sourceSample = Array(sourcePixels[center..<(center + 4)])
        let outputSample = [output[center], output[center + 1], output[center + 2], output[center + 3]]
        guard outputSample != sourceSample, outputSample[3] >= 250 else {
            throw ProbeError(message: "Custom-effect output validation did not observe the expected processed pixel.")
        }

        return ProbeResult(width: width, height: height, inputTextures: 1, intermediateTextures: 1,
            intermediateBytes: intermediateBytes, budgetBytes: intermediateBudgetBytes,
            measuredFrames: measuredFrames, gpuFrames: gpuFrames,
            averageGPUMilliseconds: gpuFrames > 0 ? gpuSeconds * 1_000 / Double(gpuFrames) : nil,
            averageWallMilliseconds: wallSeconds * 1_000 / Double(measuredFrames))
    }
}

do {
    let result = try CustomShaderEffectProbe.run()
    print(result.line)
    if let summaryPath = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"], !summaryPath.isEmpty {
        let line = "### Custom shader effect GPU probe\n\n`\(result.line)`\n\n"
        let url = URL(fileURLWithPath: summaryPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        }
    }
} catch {
    fputs("CUSTOM_SHADER_EFFECT_PROBE_ERROR \(error.localizedDescription)\n", stderr)
    exit(1)
}
