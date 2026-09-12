# Custom shader effects

Idlesse supports a bounded custom Metal effect inside the ordinary ordered Effects list. It is a single fragment pass over the current rendered layer or group texture, so masks, blend modes, ordering, Undo/Redo, recovery and package saving follow the same paths as built-in effects.

## Authoring contract

Choose **Custom Shader** in Studio’s Appearance → Effects editor and open **Edit Metal Effect…**. The entry point is:

```metal
fragment float4 effectMain(
    V in [[stage_in]],
    constant EffectU &u [[buffer(1)]],
    constant ShaderInputs &inputs [[buffer(2)]],
    texture2d<float> source [[texture(0)]])
```

`source` is the one existing layer/group texture. The initial format exposes no other texture, pass, file, network or script capability.

`EffectU.viewport` contains `(time, width, height, amount)`. `time` is multiplied by the effect’s saved speed. `amount` is the ordinary effect amount and is bounded to `0...1`. `EffectU.signals` contains `(pointerX, pointerY, audioLevel, 0)`. `ShaderInputs` is the same eight-slot block used by procedural shader nodes, backed by ordinary scene controls.

The source/speed payload uses the existing shader limits: 1–32768 UTF-8 bytes and speed 0.01–10. A scene can contain at most four custom shader effects, while the existing limit of eight total effects per layer remains in force.

Standalone procedural shader nodes remain procedural sources. The first custom-effect format applies to rendered media, text, shapes, gradients, particles and groups; it does not stack a texture-sampling custom effect directly on a procedural shader node.

## Rendering and resource accounting

Custom shader effects consume one current source texture and one destination from the renderer’s existing three-texture ordered-effect scratch set. They do not allocate an extra texture class or introduce a multipass graph. The same 128 MiB intermediate-texture cap applies to the whole frame.

The pre-format macOS smoke probe used a 1920×1080 BGRA8 private intermediate and one source texture. The measured intermediate allocation was **8,486,912 bytes** (about 6.3% of the 128 MiB cap). Across 24 measured frames after warmup, the effect averaged **0.562 ms GPU time** and **0.630 ms wall time** on the hosted Apple-silicon macOS runner. These measurements justified keeping the one-pass format.

## Compilation and updates

Studio Compile/Apply uses the Metal compiler and reports user-source line/column diagnostics. A source edit requires transactional renderer replacement, preserving the last working preview until the new pipeline prepares successfully. Amount, speed and ordinary typed-control value edits stay on the live scene-update path.

Saved revision-21 packages declare the `shader-effects` feature and round-trip the effect’s source, speed, amount and identity through the existing ordered-effect model. Implementations that do not support this feature can reject the package explicitly.
