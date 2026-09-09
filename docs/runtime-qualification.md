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

## Desktop resource and lifecycle runner

The optimized app accepts:

```sh
IDLESSE_METAL_COMPOSITOR=1 build/qualification/Idlesse.app/Contents/MacOS/Idlesse \
  --qualify-desktop /absolute/path/to/scene report.json 10 3
```

This runs three ten-second playback cycles on the actual attached desktop
surfaces. It temporarily displays the test scene and closes its own windows on
completion. The report path must be new. Duration accepts 1–7200 seconds per
cycle and cycles accepts 1–100. Run measurements serially, without another
benchmark/export in parallel.

Each cycle exercises pause, overlapping system/display/session suspension,
replacement while suspended, resume, failed replacement preserving the current
scene, and stop. Suspension is invoked through the host's lifecycle handlers;
this is not physical sleep, monitor hotplug, or audio permission-loss testing.
Existing crossfade preferences are respected, not changed. This runner does not
guarantee that a crossfade occurred.

JSON samples contain process CPU seconds, resident/physical footprint bytes,
surface count, per-surface submitted/presented counters, GPU seconds and completed
GPU frames where available. Counters restart when a surface is reconstructed.
Compute deltas only within one uninterrupted playback interval. GPU mean is
delta GPU seconds / delta GPU frames; process CPU is delta CPU seconds / wall
seconds (one core = 100%). Memory is process-wide, including decoder allocations;
it is not a decoder-specific estimate. Energy remains unmeasured.

Locked or occluded desktops can produce zero presented frames. Those samples
still exercise allocation/lifecycle, but cannot qualify visible playback cadence
or serve as a matched rendering performance comparison. A short run does not
establish multi-hour stability or absence of a slow memory leak.

### Second checkpoint: color and real media

The corpus now passes 15 packages / 120 frames, including tagged sRGB and
Display P3 images representing the same in-gamut color. Both match RGB
(64,128,192) within two code values. HDR and out-of-gamut behavior remain open.
Real 4K Evelyn H.264 and Mika HEVC sources additionally passed exact-time offline
forward/reverse replay (16 frames). Offline conformance now explicitly disables
live-player sampling after preparing its requested frame.

Release desktop runs on Mac17,4, 24 GiB, macOS 26.6.2 used two displays:
2560×1440 logical at 2× / reported 160 Hz, and 1710×1107 at 2× / 60 Hz.
Each source below passed five five-second playback cycles plus the lifecycle
transitions described above, running serially with Metal requested.

| Source | Sampled peak process footprint | Post-stop footprint, cycles 1 → 5 | Last-cycle CPU, one core | Last-cycle presented FPS, display 1 / 2 |
| --- | --- | --- | --- | --- |
| Vivian trust, H.264 960×540/60 | 353.8 MiB | 19.8 → 20.6 MiB | 15.6% | 59.6 / 52.6 |
| Shiroko Terror, HEVC 3840×2160/60 | 376.3 MiB | 21.4 → 22.0 MiB | 17.7% | 58.6 / 52.0 |

These short samples are not a codec comparison, energy claim, guarantee of source
cadence, or multi-hour soak. Peaks are sampled, not allocation-level transient
maxima. Raw reports are generated under `build/qualification/`.

An early CLI prototype appeared to retain gigabytes across repeated lifecycle
calls. Adding an event-level autorelease pool around each synchronous test cycle
removed that accumulation in the two runs above. Post-stop measurement happens
after draining the pool. This was a harness correction, not evidence of a fixed
production renderer leak. The earlier unpooled readings are not release baselines.
