# Runtime 1.0 qualification

Revision 21 is held steady during qualification. Metal remains the creative
renderer; Standard remains the compatibility path. Passing the automated suite
does not by itself promote Metal or establish energy savings.

## Reproducible checks

Build with `CONFIG=release BUILD_DIR="$PWD/build/qualification" ./build.sh app`.
Run `./test.sh`, then run both `./test-conformance.sh` and `./test-wallpaper.sh`
with `BUILD_DIR="$PWD/build/qualification"`.

`Tests/Scenes/corpus.json` is a permanent package-level corpus. The conformance
command resolves packages through LocalSceneSource and renders the production
Metal pipeline at 64×64 at four exact times, then recreates resources and visits
those times backward. It checks byte-identical replay, nonblack output, expected
animation, analytic RGB probes with two-code-value tolerance, and the intermediate
texture budget. It throws on failure even in optimized builds. It opens no windows
and grants no pointer or audio access. Audio therefore remains zero.

The small analytic scenes cover SDR solid fill, all four blend modes, a hidden
node mask, and nested group opacity. Existing authored examples exercise text,
typed controls, particles, effects, and motion through real package decoding.
These are regression checks, not high-resolution visual qualification. Repeated
output can still be consistently wrong: pixel probes are independent oracles;
determinism alone is not a visual correctness oracle. Do not regenerate expected
probe values merely to make a renderer change pass.

The existing wallpaper smoke suite additionally covers synthetic video loops,
image masks, sprite particles, composed posters, export, and host lifecycle.
It does not replace real-source or multi-hour testing.

## First-release color policy

The first-release target is SDR, with sRGB image/texture handling and SDR video
export. There is no EDR/HDR output promise. The present compositor uses 8-bit BGRA
and sRGB presentation; effect/blend arithmetic follows that encoded pipeline,
not a newly introduced linear-light compositor.

HDR input tone mapping is **not yet qualified**. Do not describe BGRA video
conversion as verified tone mapping. Before release, compare explicit SDR
reference conversions against HDR and wide-gamut sources in Desktop, Studio,
Library and Export. Either implement and verify consistent normalization or
explicitly reject unsupported inputs. This decision remains a release gate.

## Open qualification gates

| Area | Automated evidence | Still required |
| --- | --- | --- |
| Composition | Package replay, analytic probes, existing effect/mask GPU tests | High-resolution visual/color reference inspection |
| Video | Synthetic loops, offline export/posters, transport checks | Real 4K sources, two-video loop timing and color parity |
| Lifecycle | Existing smoke transitions and cancellation | Metal host abuse: crossfade sleep/wake, hotplug/span, audio loss, rotation failures |
| Resources | Intermediate pool bound | Matched release CPU, footprint, GPU, energy and switching/crossfade peaks |
| Durability | Recreated renderer/reverse-time replay | Repeated switching and multi-hour playback with sampled memory trend |

Record hardware, OS, build/configuration, scene, display size/refresh, source
codec/frame rate, duration and sampling method alongside each measurement.
Unavailable energy or decoder-memory counters must remain unavailable, not zero.
No multi-hour soak, monitor hotplug, HDR qualification, or energy comparison has
been established by the conformance command.

## September 9, 2026 checkpoint

On Apple Silicon, macOS 26.6.2 (25G83), Swift 6.3.3:

- Optimized `-O -wmo` app build passed after replacing a map/reduce layout
  expression that crashed the compiler's ownership optimizer in
  `SceneParameterControls.init` with an equivalent explicit accumulation.
- The general test suite passed.
- The release conformance run passed 13 packages / 104 frames.
- A deliberately incorrect RGB expectation failed with exit 1 in that same
  optimized executable, confirming checks remain active.
- The release wallpaper, Library and export smoke suites passed, including
  decoded video loops and export cancellation/partial-file cleanup.

These close the initial release-build and package-corpus checks only. The open
qualification gates above remain open; renderer defaults are unchanged.
