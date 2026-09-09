# Metal creative renderer

Metal is the creative renderer for styles/effects, audio and signal bindings,
tracks, and authored transport. Plain scenes retain the Standard compatibility
path; the preview workbench can compare engines. `IDLESSE_METAL_COMPOSITOR=1`
also requests Metal for plain desktop scenes. This routing is not a claim that
Metal has passed every color, power, and presentation gate below.

Images, videos, gradients, and isolated groups feed one MTKView per display.
Groups and ordered effects use bounded offscreen passes; they share a 128 MiB
target pool including cached and in-flight textures. Blur/bloom and ordered color
effects are implemented. Static scenes are event-driven; animated scenes use the
selected refresh preference and skip unchanged video compositions. At most two
frames are in flight, without blocking the display loop on GPU completion.

Video uses AVPlayerItemVideoOutput BGRA buffers and CVMetalTextureCache. The GPU
completion handler retains both the Core Video texture wrappers and pixel buffers.
Each queued loop replica owns its video output; the compositor samples the current
item and retains the last texture until its next frame arrives. There is no
per-frame CPU readback or image upload. BGRA conversion still has a cost:
this is not a claim of end-to-end zero-copy decoding. Pause stops players and drawing;
disposal releases players, textures, cache and drawables.

## Verified

`./build.sh app`, `./test.sh`, and `./test-wallpaper.sh` pass. The wallpaper suite
uses actual GPU readback to check image translation/scale/opacity against expected
pixel values, mixed image/gradient output, time-varying gradients, and nonblack
changing video pixels across three queued loops and resume after pause. Existing default-host lifecycle and hot-reload checks
still run. Probe readback is confined to tests.

## Promotion gates

- Real desktop inspection, including nonuniform image orientation, rotated video,
  alpha video, wide-gamut images and HDR sources. Current output is explicitly SDR
  sRGB; this is not an HDR/color-management parity claim.
- Comparable release-build CPU, process footprint, GPU and energy measurements for
  static, 4K video and mixed scenes on the same display. No savings measured yet.
- Real-media loop-boundary timing and memory measurements. Video now uses
  AVQueuePlayer + AVPlayerLooper with an output on each replica, removing the
  explicit end-of-file seek. Synthetic tests verify continued decoding across
  replicas; they do not establish gap-free presentation for every source.
- Exact clock authority remains open. V13 added opt-in Once/Loop video following:
  coalesced seek, playback rate, and bounded drift correction have tests. Default
  videos still play independently. This is approximate synchronization, not
  frame locking across multiple videos or displays; Ping-pong video is rejected.
- Host lifecycle integration tests with the experimental switch enabled. Existing
  tests inspect the default renderer's view hierarchy and cannot simply be run with
  that switch. Direct compositor tests cover GPU output and pause/disposal separately.

V15/V16 checks cover ordered blur/bloom output, effect order, 16 effect-bearing
layers, 8K-requested target allocations under the cap, teardown, and direct audio
modulation of bloom. Parameters, drivers, smoothing, keyframes, ellipse masks,
deterministic particles, and V18 procedural wave displacement are implemented.
V20 adds alpha/luminance image and node-output masks, plus normal/add/multiply/screen blending. Scenes using these operations compose isolated node outputs inside the same 128 MiB target budget. See docs/scenes.md.
Do not treat a windowed GPU timing sample as release-build
energy evidence or HDR parity.

API references: [AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)
and [Core Video Metal texture mapping and lifetime](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)).

Queued looping follows Apple’s [replica output configuration guidance](https://developer.apple.com/documentation/avfoundation/avplayerlooper/loopingplayeritems).
