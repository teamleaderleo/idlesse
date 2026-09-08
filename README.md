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
- PhotoKit permission/album-visibility probe in Options
- configure everything from the screen saver Options sheet

## Current status

Early prototype. The code is intentionally AppKit-first inside the screen saver bundle. A separate preview harness is included for quicker iteration.

The project uses Apple's `ScreenSaver` framework and produces a classic `.saver` bundle. GitHub Actions compiles both the preview app and the universal saver on a macOS runner and smoke-tests the Options UI at runtime.

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

### Finding Idlesse on macOS 26 Tahoe

Tahoe no longer has a top-level Screen Saver pane in System Settings. Go to:

**System Settings → Wallpaper → Screen Saver → Custom**

Then scroll to **Other** and select **Idlesse**. Once Idlesse is selected, use **Options** at the top of the Screen Saver window to open its settings.

`./build.sh install` opens the Wallpaper settings pane after installation to make this easier.

On older macOS versions, the Screen Saver settings may still appear as their own pane.

## Development notes

The screen saver host is sandboxed on modern macOS, so folder access is stored as a security-scoped bookmark created from an `NSOpenPanel` selection.

Random playback is a true shuffle bag: every readable image appears once before the deck is rebuilt, and cycle boundaries avoid immediate repeats without dropping an item. Ordered modes support name, file creation date, and file modification date in both directions.

The selected folder is rescanned every 15 seconds. Added images enter the next rebuilt order automatically, removed images stop being selected, and an empty folder begins playing again when new images appear.

The multi-display modes share one per-process shuffle seed. In **Same image on every display**, saver instances use the same deck; in **Different image on each display**, each screen starts at a different offset in that deck. Exact transition timing still follows when macOS starts each saver instance.

The real compatibility test is always the installed `.saver` inside the system screen saver host.

## Photos source

Options now includes a small PhotoKit probe. **Connect Photos…** requests read access only in response to the user clicking it; after authorization, Idlesse reports how many album collections PhotoKit can see. This does not yet use those albums as a slideshow source—the probe exists to verify Photos permission behavior in both the standalone preview and the macOS 26 screen-saver host before the slideshow engine is refactored for asynchronous PhotoKit image delivery.

See `docs/photos-source.md`.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.

Next parity work: confirm PhotoKit access in the installed saver, then make Photos albums first-class slideshow sources with preloading.
