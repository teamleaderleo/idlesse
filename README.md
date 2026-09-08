# Idlesse

A native macOS picture screensaver for people who want an image to stay on screen long enough to actually look at it.

Current prototype features:

- choose a folder of images
- optionally include subfolders
- automatically notice images added to or removed from that folder while running
- random shuffle-bag playback or ordered playback by name, creation date, or modification date
- keep each image up for seconds, minutes, or hours
- crossfade gently between images
- fit, fill, or show at actual size
- choose the background color used around fitted images
- show the same sequence on every display or offset the sequence per display
- Timing presets and keyboard-friendly preview playback controls

## Current status

Early prototype. The shipping artifact is **Idlesse.saver**, a classic ScreenSaver-framework bundle. A standalone development preview is also built for iteration, but it is not the source of truth for the installed saver.

Idlesse stores installed-saver preferences with Apple's `ScreenSaverDefaults`. The selected folder is represented by a read-only security-scoped bookmark created from inside the screen-saver host, so the sandboxed `legacyScreenSaver` process can reopen it later.

GitHub Actions compiles the development preview and the arm64 saver on a macOS runner, smoke-tests the Settings UI at runtime, and verifies both bundles.

## Requirements

- macOS 14 or newer
- Xcode command-line tools / Xcode
- Apple Silicon for the current development build

The build script produces an `arm64` saver by default. A universal build can be requested later with `ARCHS="arm64 x86_64" ./build.sh` when Intel support is actually needed.

## Build

```sh
./build.sh
```

Outputs:

```text
build/Idlesse.app
build/Idlesse.saver
```

Run the standalone development preview:

```sh
./build.sh run
```

Its settings are useful for local iteration only. Configure the installed saver from the screen-saver host.

## Install

```sh
./build.sh install
```

This installs:

```text
~/Library/Screen Savers/Idlesse.saver
```

and opens Wallpaper settings.

### macOS 26 Tahoe

Go to:

**System Settings → Wallpaper → Screen Saver → Custom**

Scroll to **Other** and select **Idlesse**.

Idlesse now follows the public `ScreenSaverView` configuration contract directly. It returns one persistent configuration window from `configureSheet`, lets System Settings run that window as the native sheet, and ends the document-modal session through `NSApplication.endSheet` when Save or Cancel is clicked. Selecting Idlesse itself never opens settings.

This is intentionally the most native third-party path available through the public ScreenSaver framework. Tahoe has known regressions around legacy third-party screen savers, so diagnostics remain enabled while this path is tested on real macOS 26 systems.

Choose the image folder in **Idlesse Settings** and press **Save**. Because the picker and bookmark creation happen inside `legacyScreenSaver`, the folder permission belongs to the process that actually displays the images.

The **Options…** button can appear a short moment after selecting Idlesse. Tahoe loads third-party `.saver` bundles through `legacyScreenSaver` and queries `hasConfigureSheet` at runtime, unlike Apple's built-in Photos UI which is already part of System Settings.

For Tahoe diagnostics after one Options click:

```sh
./build.sh diagnose
```

The diagnostic log records `hasConfigureSheet`, `configureSheet`, preview lifecycle calls, process/window state, and whether System Settings attached the returned configuration window.

## Playback behavior

Random playback is a true shuffle bag: every readable image appears once before the deck is rebuilt, and cycle boundaries avoid immediate repeats without dropping an item. Ordered modes support name, file creation date, and file modification date in both directions.

The selected folder is rescanned every 15 seconds. Added images enter the next rebuilt order automatically, removed images stop being selected, and an empty folder begins playing again when new images appear.

The multi-display modes share one per-process shuffle seed. In **Same image on every display**, saver instances use the same deck; in **Different image on each display**, each screen starts at a different offset in that deck. Exact transition timing still follows when macOS starts each saver instance.

## Photos source

Photos album playback remains a separate compatibility task. Settings explains this limitation rather than offering a permission probe that cannot play albums. The prototype probe source remains available for development.

See `docs/photos-source.md`.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.

Next work: verify repeated native Options → Cancel/Save → Options cycles on Tahoe, then continue Photos-source work and distribution hardening. Earlier local verification notes describe the superseded standalone settings experiment.

## Memory and idle work

Images are decoded with ImageIO at the backing-pixel size needed by the view,
including Retina scaling and fit/fill geometry. Each image is capped at 16 million
pixels and an 8192-pixel edge. This bounds retained image dimensions, not total
process memory or temporary decoder allocations. Extreme crops and very large
Actual Size images can lose detail at the cap. Originals remain untouched.
Only the first frame/page is displayed. Color space and orientation are retained;
there is no full-resolution fallback or persistent image cache.

The canvas retains one image while holding and two during a crossfade. Stopping
releases both images and the folder index. Hidden/minimized development previews
stop playback, and the unused host animation callback is reduced to hourly; the
30 Hz fade timer runs only during transitions. Folder refresh remains every 15
seconds, with timer tolerance for coalescing wakeups.

Run `bash test.sh` for generated-image decoder checks and `CONFIG=release ./build.sh`
for optimized bundles. This is not yet a measured whole-process comparison against
Apple's saver: the host, windows and graphics compositor have additional costs.
Large-library directory scans still run synchronously. Screensaver image decoding
now runs serially off the UI thread through the shared scene source and image
preparation path; desktop image preparation remains synchronous.

## Preview controls and timing presets

The standalone preview includes Pause/Resume (Space), Next (Right Arrow), Show in
Finder, and Settings (Command-comma). Playback controls are confined to the preview;
the installed saver keeps normal macOS wake/lock behavior. Pausing holds the
picture; minimizing or hiding the preview releases its decoded images.

Settings groups pictures, pace and presentation. Calm, Gallery and Quick presets
fill in timing fields; changes are saved only with Save. Invalid timing stays
unsaved and produces an explanation. Cloud folders must be locally downloaded;
Photos album playback is not implemented.

See [measured performance and limitations](docs/performance-2026-09-08.md).
Run `python3 Benchmarks/run.py` after a release build for isolated stress tests.

## Wallpaper prototype

The app now includes **Wallpaper…** for a desktop image or muted looping MP4/MOV,
with a menu-bar Stop control. This is separate from the screensaver and leaves
your saved macOS wallpaper intact. See [wallpaper mode](docs/wallpaper-prototype.md)
for controls, measured resource use, verification and current limitations.

## Studio

**Studio…** (⌘O) opens the scene editor: layers, canvas movement/resize/rotation,
native Undo/Redo, and Save/Save As for `.idlesse` documents. It keeps editing separate
from the running desktop. See [Studio controls and saving](docs/scene-preview.md).

## Scene runtime

The desktop host now resolves `.idlesse` scene packages asynchronously and plays
them through separate image and video renderers. See [scene format and current
limits](docs/scenes.md). The screensaver now resolves its images through the shared async source and
background image preparation. Desktop packages support two layers with opacity.

Scene format v2 adds typed nodes, positioning, rotation, scale and a built-in
animated Metal gradient. Open packages hot-reload on save, preserving the last
working scene on invalid edits. See [the creative runtime](docs/creative-runtime.md)
and the self-contained `Examples/Gradient.idlesse` example. The shared clock drives
procedural time; independent video players are not yet synchronized to it.

If the system Options button stops responding, check `./build.sh installed-status`.
Building or pushing does not update the installed saver. Close System Settings
before installing and reopen it afterward. See [the verified recovery](docs/options-recovery-2026-09-08.md).
