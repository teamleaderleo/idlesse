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
- PhotoKit permission/album-visibility probe in Settings

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

Tahoe renders the standard **Options…** button for Idlesse. The current tested Tahoe build calls Idlesse's `configureSheet` getter and successfully attaches the returned settings window when the button is clicked.

Idlesse keeps one process-wide configuration controller because Tahoe can create and discard several short-lived `ScreenSaverView` instances while the Wallpaper pane is open. Keeping the configuration window alive at process scope avoids the earlier failure where the host received a window tied to a transient preview instance.

Configuration now stays completely on the normal ScreenSaver API path: selecting Idlesse does not open settings by itself, and Idlesse does not self-present a second window. Click **Options…**, choose the image folder in **Idlesse Settings**, and press **Save**. Because the picker and bookmark creation happen inside `legacyScreenSaver`, the folder permission belongs to the process that actually displays the images.

The **Options…** button can appear a short moment after selecting Idlesse. Tahoe loads third-party `.saver` bundles through `legacyScreenSaver` and queries `hasConfigureSheet` at runtime, unlike Apple's built-in Photos saver UI which is already part of System Settings.

For Tahoe diagnostics after one Options click:

```sh
./build.sh diagnose
```

The diagnostic log records `hasConfigureSheet`, `configureSheet`, preview lifecycle calls, process/window state, and whether the host attached the settings window.

## Playback behavior

Random playback is a true shuffle bag: every readable image appears once before the deck is rebuilt, and cycle boundaries avoid immediate repeats without dropping an item. Ordered modes support name, file creation date, and file modification date in both directions.

The selected folder is rescanned every 15 seconds. Added images enter the next rebuilt order automatically, removed images stop being selected, and an empty folder begins playing again when new images appear.

The multi-display modes share one per-process shuffle seed. In **Same image on every display**, saver instances use the same deck; in **Different image on each display**, each screen starts at a different offset in that deck. Exact transition timing still follows when macOS starts each saver instance.

## Photos source

Settings includes a small PhotoKit probe. **Connect Photos…** requests read access only in response to a click and reports how many album collections that host process can see.

This is still a proof, not yet a slideshow source. Photos album playback remains a separate compatibility task.

See `docs/photos-source.md`.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.

Next work: keep validating native Tahoe configuration, then continue Photos-source work and distribution hardening.
