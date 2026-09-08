# Idlesse

A native macOS picture screensaver for people who want an image to stay on screen long enough to actually look at it.

Current prototype features:

- choose a folder of images
- optionally include subfolders
- random shuffle-bag or ordered playback
- keep each image up for seconds, minutes, or hours
- crossfade gently between images
- fit, fill, or show at actual size
- choose the background color used around fitted images
- show the same sequence on every display or offset the sequence per display
- configure everything from the screen saver Options sheet

## Current status

Early prototype. The code is intentionally AppKit-first inside the screen saver bundle. A separate preview harness is included for quicker iteration.

The project uses Apple's `ScreenSaver` framework and produces a classic `.saver` bundle. This remains the documented third-party screen saver format, while modern first-party screen savers use a newer extension mechanism that is still awkward territory for third-party distribution.

GitHub Actions compiles both the preview app and the universal saver on a macOS runner and smoke-tests the Options UI at runtime.

## Requirements

- macOS 14 or newer
- Xcode command-line tools / Xcode

The build script produces a universal `arm64` + `x86_64` saver by default.

## Build

```sh
./build.sh
```

Outputs:

```text
build/Idlesse.saver
build/Idlesse Preview.app
```

Run the preview harness:

```sh
./build.sh run
```

Install the saver for the current user:

```sh
./build.sh install
```

Then open **System Settings → Screen Saver**, select **Idlesse**, and use **Options…** to choose an image folder.

## Development notes

The screen saver host is sandboxed on modern macOS, so folder access is stored as a security-scoped bookmark created from an `NSOpenPanel` selection.

Random playback is a true shuffle bag: every readable image appears once before the deck is rebuilt, and cycle boundaries avoid immediate repeats without dropping an item.

The multi-display modes share one per-process shuffle seed. In **Same image on every display**, saver instances use the same deck; in **Different image on each display**, each screen starts at a different offset in that deck. Exact transition timing still follows when macOS starts each saver instance.

The real compatibility test is always the installed `.saver` inside the system screen saver host.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.

Next parity work: Photos library / album sources, live folder refresh, richer ordering options, and deeper multi-display testing on macOS 26.
