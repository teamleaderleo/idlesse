import Foundation
import Metal

@main struct ShaderStudioTests {
    static func main() throws {
        let diagnostic = "Shader:7:19: error: use of undeclared identifier 'mistake'"
        precondition(StudioShaderCompiler.normalizedDiagnostic(diagnostic) == "Line 7:19: error: use of undeclared identifier 'mistake'")

        let mixed = "program_source:4:2: warning: sample warning\nShader:3:5: error: sample error"
        let normalized = StudioShaderCompiler.normalizedDiagnostic(mixed)
        precondition(normalized.contains("warning: sample warning"))
        precondition(normalized.contains("Line 3:5: error: sample error"))

        if MTLCreateSystemDefaultDevice() != nil {
            try StudioShaderCompiler.compile(.init())
            let invalid = SceneNode.Shader(source: """
            fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
                return float4(missingSymbol, u.opacity);
            }
            """, speed: 1)
            do {
                try StudioShaderCompiler.compile(invalid)
                fatalError("Accepted invalid Metal shader")
            } catch {
                precondition(error.localizedDescription.contains("Line 2") || error.localizedDescription.contains("Shader:2"),
                             "Compiler diagnostic should identify the authored source line: \(error.localizedDescription)")
            }
            print("Shader Studio checks passed: Metal compile and authored-line diagnostics")
        } else {
            print("Shader Studio checks passed: diagnostic remapping; Metal device unavailable on this runner")
        }
    }
}
