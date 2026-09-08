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

One or two ordered image/video layers are supported, drawn back to front. Each
layer accepts optional `opacity` from 0 to 1 (default 1). Transparent image
foregrounds preserve the content beneath them. Layers currently fill the display;
For transforms and the new gradient node, see [scene format v2](creative-runtime.md).
Masks and blend modes beyond normal alpha composition are not implemented. Image assets use JPG/JPEG, PNG or
HEIC; video assets use MP4/MOV. Paths are relative to the package and must resolve
inside it. Each JSON document is limited to 64 KiB. Unknown versions and requested
capabilities fail explicitly. Preview art can be included but is not consumed yet.
No network access, scripts, signals or effects are implemented.

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

Scenes support 1–16 nodes, at most two videos and four gradients. Hidden nodes
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
Stop releases every child renderer. Groups and intermediate effect textures are
not implemented yet.
