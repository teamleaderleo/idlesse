# Shader authoring in Studio

Shader layers are Metal fragment shaders. Studio opens a focused editor from the persistent layer inspector, with source, speed, templates, compilation and Apply in one place.

## Authoring contract

The entry point is:

```metal
fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]])
```

`V` supplies `uv` and the scene vertex outputs. `ShaderU` supplies elapsed `time`, render `resolution`, normalized `pointer`, `audio` level and layer `opacity`. The saved `speed` multiplies elapsed time before it reaches `ShaderU.time`.

Studio ships restrained starting templates for Plasma, Noise / Grain, Star Field, Water / Ripple, CRT and Voronoi. Templates are plain source plus a speed default; they introduce no extra scene data.

## Compile and Apply

**Compile** validates the current draft with Metal without changing the scene. Compiler messages are shown in the editor and, when Metal supplies a source location, Studio reports the user-source line/column and selects the first failing line.

**Apply** compiles first and commits only a successful draft. Source changes force renderer preparation through the same replacement path Studio already uses for resource edits. The current renderer remains active until replacement succeeds, so a bad edit cannot destroy the last valid preview. Speed-only changes use the existing in-place scene update path.

A successful Apply is an ordinary Studio content edit: document Undo/Redo snapshots include shader source and speed, and Studio recovery serializes the same scene state. Draft text inside the editor uses the native text editor Undo stack until Apply.

Revision 21 remains the container version. Saved shader scenes declare the `shaders` feature and round-trip source plus speed through ordinary `.idlesse` Save/Open. Shader limits (1–32768 UTF-8 bytes, speed 0.01–10), node budgets and renderer budgets stay unchanged.

## Typed shader inputs

Shaders can read up to eight fixed typed-input slots from `ShaderInputs` at fragment buffer 2. Studio authors those inputs as ordinary scene controls, so number, toggle, color and choice values stay in the existing `SceneDescriptor.parameters` model and Controls UI. Existing two-argument procedural shaders continue to work unchanged.

See `docs/shader-inputs.md` for slot mapping, declaration limits and package behavior.

## Custom shader effects

The ordered Effects editor also supports a bounded **Custom Shader** effect. Its `effectMain` fragment samples one existing rendered layer/group texture at `texture(0)`, receives the same `ShaderInputs` block, and writes one destination in the existing effect scratch pool. The first format is single-pass and keeps standalone procedural shader nodes independent.

See `docs/shader-effects.md` for the effect ABI, source/speed and count limits, transactional update behavior, package feature gate, and measured 1080p GPU/memory cost.

Older wording that called these “GLSL shader layers” was inaccurate; Idlesse compiles Metal source at runtime.
