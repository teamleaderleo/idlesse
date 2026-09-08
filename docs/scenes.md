# Idlesse scenes

## Time and pointer signals (version 8)

V8 adds four binding sources: `time` (elapsed scene seconds), `sine` (−1…1 over
`period` seconds, default 8), `pointer.x`, and `pointer.y`. Signal bindings omit
`parameter` or leave it empty; combining a parameter and signal source is rejected.
Scale/offset and property clamping work as in v7. Period must be finite and between
0.1 and 86400 seconds. A sine binding with scale 0.3, offset 0.5 and period 8
produces a smooth 0.2…0.8 cycle. Linear time eventually reaches the property's clamp;
use sine for indefinite back-and-forth motion.

```json
{"target":{"nodeID":"7F2A0000-0000-4000-8000-000000000008","property":"style.vignette"},
 "signal":"sine","period":8,"scale":0.3,"offset":0.5}
```

Pointer scenes must declare `"capabilities":["pointer"]` in the manifest. This is
a request, not a grant: **Enable Pointer Response** is off by default in Studio
and on the desktop. The switches grant access only for that host session/scene;
opening a different scene resets the grant. Reloading the same scene preserves it.
Disabling resets pointer inputs to zero. No click, key, event-monitor, audio, network,
or accessibility access is used. All other capabilities remain rejected.

Pointer X is −1 at the left and +1 at the right of the render surface; Y is −1 at
the bottom and +1 at the top. Outside positions clamp to its edges. Each display
uses its own viewport; Studio uses its preview canvas. A missing window yields
center (0,0). This is not a global multi-display coordinate system.

Signal scenes use Metal and the existing presentation loop, with no second timer.
Time uses SceneClock and freezes during host pause/sleep/suspension; pointer sampling
also stops while paused. Video keeps its existing AVPlayer clock. Evaluation updates
metadata without replacing players or textures, and unchanged values can skip GPU
submission. A still scene with only disabled pointer bindings remains event-driven.
Binding validation runs when preparing/editing; frame evaluation skips the repeated
whole-scene validation. Existing node, binding and GPU texture budgets still apply.

Studio's **Bind…** includes signal sources, scale, offset and sine period fields.
**Remove Binding** restores the static value. The canvas does not offer live handles
for transform-bound nodes; use the binding controls. Try
`Examples/BreathingAurora.idlesse`: breathing vignette plus optional pointer tilt.
There is no smoothing, pointer velocity, audio, expression tree, or keyframe editor yet.

## Numeric controls and bindings (version 7)

V7 adds up to 16 named numeric parameters and 64 bindings. See
`Examples/ControlledAurora.idlesse` for a working scene with brightness and edge
darkness controls. A parameter has `name`, `default`, `min`, and `max` fields.
Limits and default must be finite, min must be less than max, and default must be
within the range. Parameter IDs are nonempty strings of at most 64 UTF-8 bytes.

```json
"parameters": {"amount":{"name":"Edge Darkness","default":0.7,"min":0,"max":1}},
"bindings": [{
  "target":{"nodeID":"7F2A0000-0000-4000-8000-000000000001","property":"style.vignette"},
  "parameter":"amount", "scale":1, "offset":0
}]
```

Each binding computes `parameter × scale + offset` and clamps to the target's
supported range. Scale and offset are required finite numbers. Missing references,
duplicate property targets and nonfinite results reject the scene. Bindings apply
to a render copy; static document values remain available when a binding is removed.
Evaluation happens on preparation and edits, with no new polling or frame timer.
Style bindings select Metal even when the current value is neutral.

Studio's **Bind…** creates a control for the selected property or reuses an existing
one; the scale and offset fields default to 1 and 0 and can be edited in the dialog.
**Controls…** generates sliders; Apply is undoable and saved as parameter defaults.
The wallpaper menu's **Scene Controls…** changes active values without saving the
package, restarting playback, or copying assets. Values survive suspend/resume but
reset when selecting/reloading a package or relaunching the app.

Deleting a target removes its bindings; duplicating a layer currently creates an
unbound copy. Renaming/reordering/grouping preserves references. Removing/replacing
a binding in Studio also removes its former parameter if no bindings use it.
Bound transform fields show the static fallback disabled; transform-bound layers
and their children use controls instead of canvas manipulation. Binding removal
restores ordinary canvas editing. There are no time/pointer/audio signals, color
parameters, expression trees, or keyframes in v7. V8 adds the signals described above.

## Persistent identities (version 6)

Studio saves v6 packages, v7 with controls, or v8 with signals. Every node, including groups and nested children, has an
`id` containing a UUID string. Missing, malformed, or duplicate IDs reject the
package. Save and Save As preserve IDs; duplicating a layer assigns fresh IDs to
its entire subtree. IDs are scoped to a scene, so separate copies may share IDs.
Versions 1–5 still load and receive fresh IDs, which become persistent on saving.
Older Idlesse builds reject v6 rather than silently losing identities.

The runtime's `ScenePropertyAddress` encodes a target as
`{"nodeID":"7F2A0000-0000-4000-8000-000000000001","property":"transform.x"}`.
Supported scalar properties are transform x/y/scale/rotation, opacity, and style
exposure/saturation/vignette. Reads and writes resolve recursively by UUID.
Missing targets and nonfinite/out-of-range writes fail without mutation. This is
the target vocabulary for v7 bindings. Persistent identity alone does not change the host's hot-reload
replacement behavior or synchronize video playback.

## Basic package (version 1)

The desktop app can open an inspectable `.idlesse` directory from Wallpaper… or
as a document. `Examples/Aurora.idlesse` is a template; supply its video asset.

`manifest.json`:
```json
{"version":1,"title":"Aurora","capabilities":[]}
```

`scene.json`:
```json
{"layers":[{"type":"video","asset":"assets/aurora.mp4"}]}
```

Up to 16 ordered image/video layers are supported, drawn back to front. Each
layer accepts optional `opacity` from 0 to 1 (default 1). Transparent image
foregrounds preserve the content beneath them. Layers currently fill the display;
For transforms and the new gradient node, see [scene format v2](creative-runtime.md).
V4 adds an ellipse mask and color adjustments; other mask types and blend modes
beyond normal alpha composition are not implemented. Image assets use JPG/JPEG, PNG or
HEIC; video assets use MP4/MOV. Paths are relative to the package and must resolve
inside it. Each JSON document is limited to 64 KiB. Unknown versions and requested
capabilities fail explicitly. Preview art can be included but is not consumed yet.
No network access, scripts or signal bindings are implemented.

The desktop path is now LocalSceneSource → SceneDescriptor → SceneRenderer →
WallpaperSurface. Resolution runs off the main thread, returns metadata only,
and checks cancellation before adoption. StaticImageRenderer retains the bounded
ImageIO path; VideoRenderer owns native muted looping playback. The host retains
the security-scoped package access and owns windows, pause, sleep and stop.

The screensaver now uses the same async SceneSource for its image references.
ImageLibrary returns URLs without decoding. ImagePreparation serializes image
decoding off the main thread and checks cancellation before and after decode;
the host rejects stale results after Stop or restart. Folder scanning and sorting
remain synchronous. The saver still shows images only, not layered/video packages.
A separately linkable Swift package is not yet extracted.
Cloud fetching, cache eviction, playlists and richer composition are future
work. Studio supports native layer editing and safe package saves. Scene assets must currently be locally readable, including synced files.

Run `./test.sh` for scene and image checks and `./test-wallpaper.sh` for real
renderer lifecycle checks, including a generated video scene package.

## Resource limits

Scenes support 1–16 total nodes, including group containers and their descendants,
at most two videos, four gradients, and four groups. Groups nest at most two levels deep. Hidden nodes
count toward these limits. The image nodes share 32 million decoded pixels per
display, with at most 16 million per image (roughly 128 MB of four-byte pixels
combined, excluding framework and temporary allocations). Video decoding and
display surfaces consume additional memory. Each video has its own native player.

Optional `visible` and `locked` booleans default to true and false respectively.
Hidden nodes are not drawn; their players/gradient renderers pause while retaining
resources. Locking prevents canvas manipulation, while inspector edits remain
available. Both properties round-trip through Studio and participate in undo.

Standard composes AppKit views; the experimental Metal compositor draws nodes
into one surface. Static scenes do not introduce a continuous rendering timer.
Stop releases every child renderer. Metal group textures have a separate 128 MiB
per-renderer cap, including cached targets and targets still used by the GPU.
Standard uses Core Animation group opacity; its intermediate allocations are managed
by macOS and do not share the Metal pool limit.


## Groups (version 3)

A v3 manifest uses `"version": 3`. It retains the v2 `nodes` structure and adds:

```json
{
  "nodes": [{
    "type": "group",
    "name": "Environment",
    "opacity": 0.5,
    "transform": {"x": 0.1, "scale": 0.8, "rotation": 5},
    "children": [
      {"type": "video", "asset": "assets/rain.mp4"},
      {"type": "image", "asset": "assets/neon.png"}
    ]
  }]
}
```

Children draw back to front in the group's full-canvas coordinate system. Their
result is clipped to that canvas, then transformed and faded as one layer. Overlapping
opaque children in a 50%-opacity group remain 50% opaque, not 75%. Nested group
opacity multiplies after each subtree is composed. Visibility hides and pauses the
whole subtree. A locked group cannot be moved with the canvas. Groups require at
least one child and cannot specify an asset; ordinary nodes cannot specify children.

Metal reuses private BGRA8 render targets leased through GPU completion. Target sizing uses the device allocation estimate, including GPU layout overhead. The target
size preserves aspect ratio and scales down when two in-flight frames at the current
group count would exceed the texture budget. This can reduce fine detail at large
display sizes. No group textures are allocated for flat scenes. Images, video decoders,
drawables, and a second renderer during replacement consume additional memory.
The cap is not a total process-memory guarantee.

Saving groups writes v3; flat scenes still write v2. Asset validation, file watching,
security-scoped access and save cleanup include descendants. Existing v1/v2 packages
continue to load. Older builds reject v3 explicitly.

`Examples/GroupedAurora.idlesse` demonstrates two animated children with no media download.


## Appearance (versions 4–5)

Version 5 adds optional `style.vignette`: a finite strength from 0 to 1, default 0.
It darkens RGB radially in the node's local canvas, leaving alpha and the center
unchanged. On a group it affects the composed subtree once. It shares the existing
Metal shading pass and allocates no additional textures. Nonzero vignette requires
v5 or later. See
`Examples/VignetteAurora.idlesse` for a minimal editable sample.

V4 adds optional `style` to any node, including a group:

```json
{"type":"gradient","style":{"mask":"ellipse","exposure":-0.5,"saturation":0.4}}
```

Omitted style is neutral. Within style, omitted mask means no mask, exposure defaults
to zero and saturation to one. Exposure must be finite in −2…2 and saturation in
0…2. Unknown mask names fail decoding. Styles in older format versions are rejected;
Studio saves v6, v7 or v8 to preserve layer identities, controls and signals.

The ellipse fits the node's local canvas. Its edge is antialiased in the Metal
fragment shader. Color adjustment uses Rec.709 luma weights on the current SDR
texture values, then scales by `2^exposure` and clamps to SDR. This is an artistic
SDR adjustment, not an HDR or color-managed photographic exposure pipeline.
Group effects operate on the composed group, before its opacity and transform.
Masks/color require no additional intermediate textures beyond existing group targets.

Styled scenes require Metal and select it automatically in preview and wallpaper.
Direct Standard renderer preparation rejects them rather than ignoring the effects.
Core Image view filters were not added: Apple's [filter rendering documentation](https://developer.apple.com/documentation/appkit/nsview/layerusescoreimagefilters)
explains that they move the layer hierarchy into in-process rendering. The current
effects stay in the existing Metal pass instead.

`Examples/StyledAurora.idlesse` demonstrates masked, desaturated group composition.
Arbitrary asset masks, blur, bloom and displacement remain future work.
