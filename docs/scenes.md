# Idlesse scenes

Current revision 21 authoring additions: [typed controls, text/shapes, local presets and metadata](reusable-scenes.md).

## Composable drivers (version 9)

V9 bindings retain the v7/v8 primary source and `scale`/`offset`, then apply up to
eight ordered `modifiers`. Each modifier has `operation` (`multiply` or `add`)
and exactly one operand: a numeric `value` or existing `parameter` ID. The final
result is clamped to the target property range. Intermediate nonfinite results,
missing parameters and excessive modifier counts are rejected.

For example, pointer rotation with adjustable strength:

```json
{"target":{"nodeID":"7F2A0000-0000-4000-8000-000000000009","property":"transform.rotation"},
 "signal":"pointer.x","scale":3,"offset":0,
 "modifiers":[{"operation":"multiply","parameter":"parallax"}]}
```

Older bindings have an empty modifier stack and keep their behavior. Modifier
scenes require Metal. Studio's Bind sheet can multiply the result by an existing
control; ordered stacks can also be authored in JSON. Controls continue to use
the existing Controls panel. See `Examples/AdjustableAurora.idlesse` for breathing
and parallax strengths. This initial driver vocabulary has no smoothing, tracks,
remapping or scripting; it allocates no additional GPU textures or timers.

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

Studio saves v6 packages, v7 with controls, v8 with signals, or v9 with modifiers. Every node, including groups and nested children, has an
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
Studio chooses the lowest format version needed by the authored features.

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

## V10 keyframe sources

A binding can use `keyframes` instead of `parameter` or `signal`. The track contains `interpolation` (`hold`, `linear`, or `easeInOut`) and 1–128 `keys`, each with numeric `time` and `value`. Times must strictly increase within 0–86400 seconds; values must be finite and within ±1000000. The existing 64-binding and 64 KiB JSON limits still apply. V1–V9 remain readable; tracks require V10.

Tracks sample SceneClock time, hold endpoint values outside their range, then apply the binding scale/offset, ordered modifiers, and final property clamp. Ease-in-out uses smoothstep. No extra timer or GPU texture is allocated for tracks. Metal renders them; video playback remains independent.

`Examples/KeyframedAurora.idlesse` rotates a gradient over six seconds. The example now uses V11 authored playback to repeat its six-second animation on the desktop.


## V11–V13 playback and smoothing

V11 adds optional top-level `timeline`, for example `{"duration":6,"mode":"loop","rate":1}`. Modes are `once`, `loop`, `pingPong`; duration is 0.01–86400 seconds and rate is 0.1–4 (default 1). Omission preserves unbounded scene time. Playback… edits this document data; Time… is a temporary Studio override.

V12 adds a binding `smoothing` time constant in real seconds, 0–5 (default 0/off), for signal/keyframe sources. Runtime exponential filtering follows modifiers and precedes property clamping. Filter history stays in the renderer and resets on explicit seek, scene edits, or pause/resume; no history is serialized.

V13 adds `timeline.videosFollowScene` (default false). Enabled videos use independently managed items and approximately follow the scene playhead/rate. Short sources repeat; Once holds its endpoint. Follow mode supports Once and Loop, and rejects Ping-pong. Seeking is coalesced; running drift correction uses a 120 ms tolerance, not frame locking. Disabled videos retain their existing independent AVPlayerLooper path. See [Studio documentation](scene-preview.md) for authoring controls and limits.

## V14 audio signals

V14 adds the explicit `audio` manifest capability and `audio.level`, `audio.bass`,
`audio.mid`, and `audio.treble` binding sources. The capability declares intent;
it does not enable capture. Studio and the desktop each require a session opt-in.
Signals are zero while disabled or when no fresh input arrives. Existing modifiers,
parameters, smoothing and property clamps apply unchanged. No audio is embedded in
packages. Audio Aurora includes a generated Audio Sensitivity control.

Levels are bounded 0–1 RMS envelopes. Approximate crossover bands use 200 Hz and
2 kHz boundaries, with DC removal, 30 ms attack and 180 ms release. These are broad
creative controls, not calibrated spectral measurements. The analyzer uses fixed
state, handles stereo without phase cancellation, and keeps no sample history.

The app uses one private Core Audio process tap for all active hosts, on macOS 14.2+.
It does not mute output or record/save/transmit audio. Stopping the last consumer
destroys the private aggregate device and tap. Sleep, lock, pause, hiding Studio,
and Low Power Mode stop the relevant host's demand. Stale levels expire after 0.5 s.
Native capture supports Float32 mono/stereo; other formats produce an error.

Implementation reference: [Apple’s Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

## V15 ordered effects

`style.effects` is an optional ordered array of up to eight `{ "type", "amount" }`
objects per node. Types are `blur` (0–24), `bloom` (0–2), `exposure` (−2–2),
`saturation` (0–2), and `vignette` (0–1). Effects run top to bottom before the
existing style fields, mask, opacity, and transform. Existing packages retain their
fixed appearance behavior. New stacks require V15 and Metal. Groups apply a stack
to their composited children; any node type can use the same stack.

Blur uses two nine-tap separable Gaussian passes. Its radius is measured in pixels
at a 1080-pixel scene height and scales with the canvas. Bloom soft-selects bright
pixels (0.55–0.85 SDR), blurs at a fixed 12-pixel radius, then adds the result with
the authored strength. Both preserve premultiplied alpha. These are SDR effects;
they do not imply HDR support. Boundaries clamp to the node's canvas.

Effect nodes lease three reusable targets each. All effect and group targets share
the existing 128 MiB per-renderer pool, including in-flight and cached targets.
Resolution falls uniformly when needed to stay inside the cap; more effects can
therefore reduce intermediate resolution. Each node reuses its three targets across
the entire stack. Static scenes remain event-driven. Stack changes update an existing
Metal renderer without restarting its media. V15 amounts are static; V16 adds
identified effect targets for animation, described below.

## V16 effect identities and animation

Every effect now saves a UUID `id`. V15 packages still load: missing effect IDs are
created on import, then persist when saved as V16. V16 rejects missing or duplicate
effect IDs. Recovery drafts from before this change receive IDs on recovery.

An effect target is `{ "nodeID": "…", "property": "effect.amount", "effectID": "…" }`.
It works with parameters, signals, modifiers, smoothing, and keyframe tracks. The
final value clamps to the selected effect's range (e.g. bloom 0–2, blur 0–24).
Missing targets and effect IDs attached to ordinary properties are invalid.
Reordering preserves targets; removing an effect in Studio removes only its bindings.
Duplicating a layer/group creates new node/effect IDs and copies its bindings onto
the corresponding new targets. Shared parameter references stay shared. A duplicate
that would exceed the 64-binding limit is rejected.

Audio Aurora now binds bass directly to bloom strength, with sensitivity and
smoothing; its final vignette still follows audio level. No new capability or
automatic audio grant is introduced.

## V17 deterministic particles

The Metal-only `particles` node carries an `emitter` object: `count` (1–512),
`lifetime` (0.1–60 seconds), `speed`, `wind`, `gravity` (each −1…1), `size`
(0.001–0.05 of canvas height), and integer `seed` (0–65535). All fields are
required in package JSON. At most four emitters/2048 instances are allowed per
scene, within the existing 16-node cap. Particles are warm-colored soft discs.

Birth phases are evenly spaced over one lifetime. Integer hashing of seed and
instance index determines origin and size/speed variation. Position is origin +
velocity × age + gravity × age²/2; fade-in/out hides recycling. The entire emitter
repeats every lifetime. No particle-state buffer, CPU simulation, or frame history
is retained. Instance quads use the normal Metal pipeline; effects reuse the same
bounded offscreen pool. Large counts and sizes still have fill-rate costs.

`emitter.size`, `emitter.wind`, and `emitter.speed` are property targets for
parameters, signals, smoothing, and keyframes. Their values modulate the analytic
formula at the current time; wind is not a historical force integral. Count,
lifetime, gravity and seed are authored constants in this version. There is no
variable emission-rate integration or per-particle scripting. Seeking to the same
time with the same evaluated properties reproduces the same result. Stateful
smoothing retains its existing seek-reset semantics.

`Examples/Fireflies.idlesse` is a six-second looping particle scene. Its particles
already have soft radial glows; the default omits a costly full-scene bloom pass.

## V18 wave displacement

`{ "id": "…", "type": "displacement", "amount": 0.04 }` warps the preceding
effect output with two perpendicular sine fields. Amount is 0–0.1 of canvas
height, with aspect correction on the horizontal axis. The wave phase repeats
every eight scene seconds; seeking and authored transport use SceneClock.
Edges clamp to the node canvas. This first displacement implementation is a
procedural wave, not an imported displacement-map asset.

It is one additional sampling pass and reuses the effect node's existing three
targets. No extra texture pool is allocated. Nonzero displacement animates a
still image or static group; zero returns otherwise-static scenes to event-driven
rendering. Bind its identified amount to parameters, keyframes, or input signals
using V16 targets. `Examples/Ripple.idlesse` exposes Ripple Strength as a control.
# V19–V20: shared canvases and compositing

V19 adds optional `"canvas": "desktopSpan"` to scene.json. Omitting it (or using
`perDisplay`) repeats the scene on every display. Desktop-span uses the union of
display frames in logical points. Each display samples its viewport, retaining
gaps and unequal sizes. Pointer bindings use this union with host opt-in. Studio
Playback exposes the choice. Video synchronization remains approximate.

V20 adds optional node fields:

- `blend`: `normal`, `add`, `multiply`, or `screen`.
- `maskAsset`: contained image path, such as `assets/silhouette.png`.
- `maskNodeID`: another node UUID, mutually exclusive with maskAsset.
- `maskChannel`: `alpha` (default) or `luma`; transparent pixels contribute zero luminance.
- `sprite`: contained image path, for particles only; omission uses gold discs.

Masks cover the logical scene canvas after the target's transform and effects.
Image masks stretch to the canvas. Node masks use the source's transformed,
styled output, including its masks/effects, before blending with siblings.
Hidden nodes can supply masks; animated sources continue updating. To position
an image mask, use an image node. Missing references and cycles through masks or
groups are rejected. Group duplication remaps internal references.

Studio offers Mask & Blend alongside Appearance, and sprite selection in Emitter.
Sprites retain their aspect ratio and the existing seeded, seekable particle
motion and fades. Animated sprite sequences and atlases are not supported.

Save/Save As stores a shared source file once even when used by several layers, masks, or sprites.
Additional images share the 32-million-decoded-pixel allowance. Isolated node
frames and scratch textures share the 128 MiB intermediate budget across two
in-flight frames. Large compositions downsample intermediate targets. Simple
scenes avoid these additional passes.

## Offline video export

Studio Export Video writes silent HEVC MP4 at 1080p/4K, 30/60 fps, for 0.1–60
seconds. Authored rate, looping, ping-pong and drivers use exact frame times.
Opted-in video transport follows scene time; ordinary videos loop on elapsed
export time. Video frames are decoded explicitly rather than captured from
real-time playback. Pointer/audio inputs are zero; no capability is granted.

Output is SDR Rec.709 from sRGB compositor pixels; HDR is not preserved. The
encoder pool is limited to three frames. Progress is cancellable, partial files
are removed, and existing movies are never replaced. Export includes no audio
track and does not make non-looping content seamless.

The same exporter is available from the app executable:

```sh
Idlesse --export-video input.idlesse output.mp4 8 30 1920
Idlesse --smoke-export source.mp4
```

Frames end at `(frameCount - 1) / fps`, without a duplicate endpoint. Studio and
export show the whole scene in their output aspect ratio, rather than capturing
the current physical monitor arrangement.
