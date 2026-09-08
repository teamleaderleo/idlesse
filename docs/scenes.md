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
transforms, masks and blend modes beyond normal alpha composition are not implemented. Image assets use JPG/JPEG, PNG or
HEIC; video assets use MP4/MOV. Paths are relative to the package and must resolve
inside it. Each JSON document is limited to 64 KiB. Unknown versions and requested
capabilities fail explicitly. Preview art can be included but is not consumed yet.
No network access, scripts, signals or effects are implemented.

The desktop path is now LocalSceneSource → Playable → SceneRenderer →
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
Cloud fetching, cache eviction, playlists, richer composition and Studio are future
work. Scene assets must currently be locally readable, including synced files.

Run `./test.sh` for scene and image checks and `./test-wallpaper.sh` for real
renderer lifecycle checks, including a generated video scene package.

## Resource limits

At most two layers per scene. Each image keeps the existing 16-million-pixel
limit; two images can therefore retain up to roughly 128 MB of decoded pixels
per display, excluding framework allocations. Each video layer has its own
native player. Layered scenes are not promised the memory cost of a single image.
Static layers do not introduce a continuous rendering timer. Pause reaches every
video; Stop releases every child renderer. No Metal compositor is introduced yet.
