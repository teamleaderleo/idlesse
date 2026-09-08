# Metal compositor experiment

The desktop host can use `MetalSceneRenderer` by launching the development app with
`IDLESSE_METAL_COMPOSITOR=1`. The default remains `LayeredSceneRenderer`; this is a
comparison path, not a performance win established by measurement. The saver is unaffected.

The compositor draws existing v1/v2 image, video and gradient nodes into one MTKView
and one render pass per display. It supports aspect fill, normalized translation,
scale, rotation, array ordering and premultiplied opacity. Images are decoded to the
display budget and uploaded once. Static scenes redraw on activation/resize instead
of maintaining an animation timer. Animated scenes request 60 fps; submissions are
bounded to two in flight and never wait for GPU completion in the display loop.

Video uses AVPlayerItemVideoOutput BGRA buffers and CVMetalTextureCache. The GPU
completion handler retains both the Core Video texture wrappers and pixel buffers.
There is no per-frame CPU readback or image upload. BGRA conversion still has a cost:
this is not a claim of end-to-end zero-copy decoding. Pause stops players and drawing;
disposal releases players, textures, cache and drawables.

## Verified

`./build.sh app`, `./test.sh`, and `./test-wallpaper.sh` pass. The wallpaper suite
uses actual GPU readback to check image translation/scale/opacity against expected
pixel values, mixed image/gradient output, time-varying gradients, and nonblack
video decoding across a loop. Existing default-host lifecycle and hot-reload checks
still run. Probe readback is confined to tests.

## Promotion gates

- Real desktop inspection, including nonuniform image orientation, rotated video,
  alpha video, wide-gamut images and HDR sources. Current output is explicitly SDR
  sRGB; this is not an HDR/color-management parity claim.
- Comparable release-build CPU, process footprint, GPU and energy measurements for
  static, 4K video and mixed scenes on the same display. No savings measured yet.
- Seamless video looping. The experimental AVPlayer currently seeks at end of file;
  it can visibly pause at the boundary.
- Clock authority. Gradients use SceneClock, but videos still use AVPlayer time;
  neither multi-video nor multi-display frame synchronization is implemented.
- Host lifecycle integration tests with the experimental switch enabled. Existing
  tests inspect the default renderer's view hierarchy and cannot simply be run with
  that switch. Direct compositor tests cover GPU output and pause/disposal separately.

After those gates, add offscreen group composition with explicit texture budgets,
then masks/blend modes and a small effect vocabulary. Declarative parameters and
bindings should precede scripts. A small editor can then reuse the package watcher.
Keep node limits until resource budgets cover the richer composition graph.

API references: [AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)
and [Core Video Metal texture mapping and lifetime](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)).
