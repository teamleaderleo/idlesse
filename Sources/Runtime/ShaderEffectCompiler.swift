import Foundation
import Metal

/// Fixed ABI for one-input custom shader effects. `viewport` is
/// (time, width, height, amount); `signals` is (pointerX, pointerY, audio, 0).
struct ShaderEffectUniforms {
    var viewport = SIMD4<Float>.zero
    var signals = SIMD4<Float>.zero
}

enum MetalShaderEffectCompiler {
    static let sourceName = "StudioShaderEffect"
    static let defaultSource = """
    fragment float4 effectMain(V in [[stage_in]], constant EffectU &u [[buffer(1)]], constant ShaderInputs &inputs [[buffer(2)]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        uv.x += sin(uv.y * 18.0 + u.viewport.x * 1.4) * (0.012 * u.viewport.w);
        float4 pixel = source.sample(sample, uv);
        float3 shifted = float3(pixel.b, pixel.r, pixel.g);
        pixel.rgb = mix(pixel.rgb, shifted, 0.18 * u.viewport.w);
        return pixel;
    }
    """

    private static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; float fade; float2 canvasUV; };
    struct EffectU { float4 viewport; float4 signals; };
    """

    private static let validationVertex = """
    vertex V studioShaderEffectValidationVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        const float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
        V out;
        out.position = float4(positions[id], 0.0, 1.0);
        out.uv = uvs[id];
        out.fade = 1.0;
        out.canvasUV = out.uv;
        return out;
    }
    """

    static func makeLibrary(_ shader: SceneNode.Shader, inputs: [MetalShaderInput] = [],
                            device: MTLDevice) throws -> MTLLibrary {
        try shader.validate()
        let combined = prelude + "\n" + MetalShaderInput.metalDeclaration(inputs) + "\n" + validationVertex +
            "\n#line 1 \"\(sourceName)\"\n" + shader.source
        do {
            return try device.makeLibrary(source: combined, options: nil)
        } catch {
            throw MetalShaderCompilationError(diagnostics: MetalShaderCompiler.parseDiagnostics(error.localizedDescription),
                                              fallback: error.localizedDescription)
        }
    }

    private static func makeReflectedPipeline(_ descriptor: MTLRenderPipelineDescriptor,
                                              device: MTLDevice) throws -> MTLRenderPipelineState {
        do {
            let (state, reflection) = try device.makeRenderPipelineState(descriptor: descriptor, options: .argumentInfo)
            try validateResources(reflection)
            return state
        } catch let error as SceneError {
            throw error
        } catch {
            throw MetalShaderCompilationError(diagnostics: MetalShaderCompiler.parseDiagnostics(error.localizedDescription),
                                              fallback: error.localizedDescription)
        }
    }

    /// Reflection is the format boundary: the fragment stage gets exactly one read-only 2D
    /// source texture at texture(0), plus the fixed EffectU/ShaderInputs constant buffers.
    /// This rejects samplers supplied as arguments, argument-buffer/nested resources,
    /// writable textures, extra buffers, acceleration structures and other GPU capability.
    private static func validateResources(_ reflection: MTLRenderPipelineReflection?) throws {
        guard let reflection else { throw SceneError.invalid("Metal could not reflect the shader-effect resource bindings.") }
        var sourceTextures = 0
        for binding in reflection.fragmentBindings where binding.isUsed {
            guard binding.isArgument else {
                throw SceneError.invalid("Shader effects cannot use nested or argument-buffer resources.")
            }
            guard binding.access == .readOnly else {
                throw SceneError.invalid("Shader-effect resources must be read-only.")
            }
            switch binding.type {
            case .buffer:
                guard binding.index == 1 || binding.index == 2 else {
                    throw SceneError.invalid("Shader effects may only use EffectU at buffer(1) and ShaderInputs at buffer(2).")
                }
            case .texture:
                guard binding.index == 0, let texture = binding as? MTLTextureBinding,
                      texture.textureType == .type2D, texture.arrayLength == 1, !texture.isDepthTexture else {
                    throw SceneError.invalid("Shader effects may only sample one non-array 2D source texture at texture(0).")
                }
                sourceTextures += 1
            default:
                throw SceneError.invalid("Shader effects may only bind the fixed constant buffers and source texture(0).")
            }
        }
        guard sourceTextures == 1 else {
            throw SceneError.invalid("Shader effects must sample exactly one source texture at texture(0).")
        }
    }

    static func validate(_ shader: SceneNode.Shader, inputs: [MetalShaderInput] = [],
                         device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw SceneError.invalid("Metal is unavailable on this Mac.") }
        let library = try makeLibrary(shader, inputs: inputs, device: device)
        guard let fragment = library.makeFunction(name: "effectMain") else {
            throw SceneError.invalid("Shader effects must define fragment float4 effectMain(V, EffectU, ShaderInputs, texture2d<float> source).")
        }
        guard let vertex = library.makeFunction(name: "studioShaderEffectValidationVertex") else {
            throw SceneError.invalid("The shader-effect validation vertex function is unavailable.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0]?.pixelFormat = .bgra8Unorm
        _ = try makeReflectedPipeline(descriptor, device: device)
    }

    static func makePipeline(_ shader: SceneNode.Shader, inputs: [MetalShaderInput], device: MTLDevice,
                             vertex: MTLFunction) throws -> MTLRenderPipelineState {
        let library = try makeLibrary(shader, inputs: inputs, device: device)
        guard let fragment = library.makeFunction(name: "effectMain") else {
            throw SceneError.invalid("Shader effects must define effectMain.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0]?.pixelFormat = .bgra8Unorm
        return try makeReflectedPipeline(descriptor, device: device)
    }
}
