# Idlesse

A native macOS picture screensaver for people who want an image to stay on screen long enough to actually look at it.

The first vertical slice is deliberately small:

- choose a folder of images
- optionally include subfolders
- show images in random or ordered sequence
- keep each image up for seconds, minutes, or hours
- crossfade gently between images
- fit, fill, or show at actual size
- configure everything from the screen saver Options sheet

## Current status

Early prototype. The code is intentionally AppKit-first inside the screen saver bundle. A separate preview harness is included for quicker iteration.

The project uses Apple's `ScreenSaver` framework and produces a classic `.saver` bundle. This remains the documented third-party screen saver format, while modern first-party screen savers use a newer extension mechanism that is still awkward territory for third-party distribution.

GitHub Actions compiles both the preview app and the universal saver on a macOS runner so compiler regressions are caught before changes land.

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

For now the preview harness shares the same preference code, but the real compatibility test is always the installed `.saver` inside the system screen saver host.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.
