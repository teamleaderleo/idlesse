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
- PhotoKit permission/album-visibility probe in the companion app
- a native Idlesse companion app for settings and live preview

## Current status

Early prototype. Idlesse has two pieces:

- **Idlesse.app** — the canonical settings surface and live preview.
- **Idlesse.saver** — the actual ScreenSaver-framework bundle macOS runs.

This split is intentional on macOS 26 Tahoe. Tahoe still lists third-party `.saver` bundles, but its legacy Screen Saver **Options** button can fail to call or present a third-party configuration sheet. Idlesse therefore does not depend on that button.

GitHub Actions compiles the companion app and the universal saver on a macOS runner, smoke-tests the Settings UI at runtime, and verifies both bundles.

## Requirements

- macOS 14 or newer
- Xcode command-line tools / Xcode

The build script produces a universal `arm64` + `x86_64` saver by default. The companion app is built for the current Mac architecture.

## Build

```sh
./build.sh
```

Outputs:

```text
build/Idlesse.app
build/Idlesse.saver
```

Run Idlesse without installing it:

```sh
./build.sh run
```

The app opens the Settings window and keeps a live screensaver preview behind it.

## Install

```sh
./build.sh install
```

This installs:

```text
~/Applications/Idlesse.app
~/Library/Screen Savers/Idlesse.saver
```

and opens **Idlesse.app**. Choose the image folder and other settings there.

### Selecting Idlesse on macOS 26 Tahoe

Go to:

**System Settings → Wallpaper → Screen Saver → Custom**

Scroll to **Other** and select **Idlesse**.

Tahoe may show an **Options…** button for Idlesse that does nothing. That is a `legacyScreenSaver` host regression; configure Idlesse in **Idlesse.app** instead. The `.saver` keeps the standard `configureSheet` implementation for older macOS versions and for any future Tahoe fix.

## Shared settings

The companion app and the sandboxed screen saver must see the same preferences. `ScreenSaverDefaults` is redirected by the `legacyScreenSaver` container, so an external app cannot reliably configure the saver through defaults alone.

Idlesse now stores one JSON settings file inside the legacy screen-saver container. The companion app reaches it through the user's normal home directory; the saver reaches the same file through its sandboxed home directory. The selected folder is stored as a read-only security-scoped bookmark.

The old prototype's `ScreenSaverDefaults` values are migrated by Idlesse.app when possible.

## Playback behavior

Random playback is a true shuffle bag: every readable image appears once before the deck is rebuilt, and cycle boundaries avoid immediate repeats without dropping an item. Ordered modes support name, file creation date, and file modification date in both directions.

The selected folder is rescanned every 15 seconds. Added images enter the next rebuilt order automatically, removed images stop being selected, and an empty folder begins playing again when new images appear.

The multi-display modes share one per-process shuffle seed. In **Same image on every display**, saver instances use the same deck; in **Different image on each display**, each screen starts at a different offset in that deck. Exact transition timing still follows when macOS starts each saver instance.

## Photos source

Idlesse.app includes a small PhotoKit probe. **Connect Photos…** requests read access only in response to a click and reports how many album collections the companion app can see.

This is still a proof, not yet a slideshow source. PhotoKit authorization for the companion app does not automatically prove that Tahoe's sandboxed legacy screen-saver host can fetch those assets, so album playback remains a separate compatibility task.

See `docs/photos-source.md`.

## Product direction

The point is restraint. No feed, account, subscription, curation engine, motion effects, or slideshow theatrics. The image gets time.

Next work: verify that the companion app's shared folder bookmark is redeemable by the installed Tahoe saver, then harden installation/distribution and continue the Photos-source investigation.
