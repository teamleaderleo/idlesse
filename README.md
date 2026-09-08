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
- PhotoKit permission / album-visibility probe
- a companion **Idlesse.app** for configuration and live preview

## Current status

Early prototype. The project now has two pieces:

- `Idlesse.app` — the canonical settings UI and live preview
- `Idlesse.saver` — the classic ScreenSaver bundle macOS runs

This split is intentional on macOS 26 Tahoe. Tahoe can display a legacy screen saver’s **Options…** button while failing to present the configuration window behind it. Idlesse keeps the standard `configureSheet` hook for systems where it works, but configuration no longer depends on that host behavior.

The companion app and saver read the same JSON settings document inside the `legacyScreenSaver` container. Folder selection is persisted as a document-scoped security bookmark owned by that settings document, so the sandboxed saver can resolve the folder chosen in the companion app.

GitHub Actions compiles the companion app and the universal saver on a macOS runner, smoke-tests the settings UI at runtime, and verifies both bundles.

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
build/Idlesse.app
build/Idlesse.saver
```

Run Idlesse locally:

```sh
./build.sh run
```

Install both the app and saver for the current user:

```sh
./build.sh install
```

That installs:

```text
~/Applications/Idlesse.app
~/Library/Screen Savers/Idlesse.saver
```

`./build.sh install` opens **Idlesse.app**. Choose the picture folder and save your settings there.

### Finding Idlesse on macOS 26 Tahoe

Go to:

**System Settings → Wallpaper → Screen Saver → Custom**

Then scroll to **Other** and select **Idlesse**.

Tahoe currently has regressions around configuration windows for third-party legacy `.saver` bundles. The **Options…** button may do nothing. Use **Idlesse.app** for configuration; the saver reloads the shared settings while it runs.

To reopen Wallpaper settings from the terminal:

```sh
./build.sh wallpaper
```

## Development notes

The companion app is sandboxed and requests read-only user-selected file access plus Photos access. On current macOS versions, the first attempt to save screen-saver settings may also trigger a system permission prompt because the app writes the shared settings document into the `legacyScreenSaver` container.

Random playback is a true shuffle bag: every readable image appears once before the deck is rebuilt, and cycle boundaries avoid immediate repeats without dropping an item. Ordered modes support name, file creation date, and file modification date in both directions.

The selected folder is rescanned every 15 seconds. Added images enter the next rebuilt order automatically, removed images stop being selected, and an empty folder begins playing again when new images appear.

The multi-display modes share one per-process shuffle seed. In **Same image on every display**, saver instances use the same deck; in **Different image on each display**, each screen starts at a different offset in that deck. Exact transition timing still follows when macOS starts each saver instance.

## Photos source

The Idlesse app includes a PhotoKit probe. **Connect Photos…** requests read access only in response to the user clicking it; after authorization, Idlesse reports how many album collections PhotoKit can see.

This does not yet use those albums as a slideshow source. The next step is to make Photos albums first-class sources and preload PhotoKit images before transitions.

See `docs/photos-source.md`.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.
