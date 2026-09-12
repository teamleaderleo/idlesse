# Typed shader inputs

Idlesse shader inputs reuse scene controls. There is no separate runtime parameter store: values live in `SceneDescriptor.parameters`, use the existing number/toggle/color/choice controls, serialize through the existing scene package path, and can be addressed by future variant tooling exactly like other scene controls.

## Studio authoring

Select a shader layer, create a scene control, leave it unconnected, and fill in **Shader input identifier** plus **Shader slot**. Slots are `0` through `7`. Text controls are intentionally excluded.

Studio persists the declaration on the ordinary control name as a readable suffix such as:

```text
Gain [shader:0:gain]
Tint [shader:1:tint]
Enabled [shader:2:enabled]
Mode [shader:3:mode]
```

The Controls sheet hides that suffix and presents `Gain`, `Tint`, `Enabled`, and `Mode` with the normal scene-control widgets.

Shader source can add the fixed input block at fragment buffer 2:

```metal
fragment float4 shaderMain(
    V in [[stage_in]],
    constant ShaderU &u [[buffer(1)]],
    constant ShaderInputs &inputs [[buffer(2)]])
{
    float gain = inputs.slot0.x;
    float4 tint = inputs.slot1;
    bool enabled = inputs.slot2.x >= 0.5;
    int mode = int(inputs.slot3.x);
    float amount = enabled ? gain : 0.0;
    return float4(tint.rgb * amount * u.opacity, tint.a * u.opacity);
}
```

The eight-slot `ShaderInputs` ABI is always available, so Studio can compile shader source without scanning Metal text or inventing a second declaration language inside the shader. Existing procedural shaders can keep their current two-argument `shaderMain` signature and ignore buffer 2.

## Value mapping

Each slot is one `float4` (16 bytes), for a fixed 128-byte input block:

- number: value in `.x`;
- boolean: `0` or `1` in `.x`;
- choice: zero-based selected-choice index in `.x`;
- color: normalized RGBA in `.rgba`.

Changing one of these values through ordinary Scene Controls updates the uniform block in place. Changing shader source still follows the transactional compile/replacement path from Track C.

## Declaration and validation limits

The declaration helper also accepts newline-delimited JSON for package tooling and tests. Each line becomes an ordinary `SceneParameter` immediately; the declaration text is not saved as another value store. Example:

```json
{"id":"gain","slot":0,"name":"Gain","type":"number","default":0.5,"min":0,"max":1}
{"id":"tint","slot":1,"name":"Tint","type":"color","default":"#FF4FA3"}
{"id":"enabled","slot":2,"name":"Enabled","type":"boolean","default":true}
{"id":"mode","slot":3,"name":"Mode","type":"choice","default":"soft","choices":["soft","hard"]}
```

Limits are deliberately small:

- at most 8 shader inputs, occupying unique slots `0...7`;
- at most 16 scene controls total, preserving the existing scene limit;
- declaration text at most 8,192 UTF-8 bytes;
- shader identifiers at most 24 ASCII letters/digits/underscores, beginning with a letter or underscore and excluding Metal keywords plus the reserved `idlesse` prefix;
- persisted control name plus slot annotation at most 80 characters;
- choice/count, numeric range, color, and other value validation reuse `SceneParameter` limits.

Duplicate slots or identifiers, connected layer-property targets, string controls, malformed values, and oversized declarations are rejected before rendering.

## Package compatibility

No scene-format revision or new manifest feature is introduced. The shader source still uses the existing `shaders` feature and input values still use the existing typed-control encoding. A save/load cycle therefore round-trips through the same `SceneParameter` Codable path already used by Studio and desktop controls.
