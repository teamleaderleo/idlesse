# Idlesse scenes, version 1

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
v5; the writer retains earlier versions when this effect is unused. See
`Examples/VignetteAurora.idlesse` for a minimal editable sample.

V4 adds optional `style` to any node, including a group:

```json
{"type":"gradient","style":{"mask":"ellipse","exposure":-0.5,"saturation":0.4}}
```

Omitted style is neutral. Within style, omitted mask means no mask, exposure defaults
to zero and saturation to one. Exposure must be finite in −2…2 and saturation in
0…2. Unknown mask names fail decoding. Styles in older format versions are rejected;
saving writes v4 for non-neutral mask/color styles, or v5 when vignette is nonzero.

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
