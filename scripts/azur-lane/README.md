# Azur Lane intake

One command inventories only Azur Lane's game asset folder, pulls the explicitly selected skins, compares SHA-256 hashes against the device, and reports textures, animation clip names and physics assets:

```sh
build/ba-export-study/.venv/bin/python scripts/azur-lane/intake.py \
  --serial '<serial from adb devices>' \
  --output build/azur-lane-study --inspect
```

Requires an already-authorized Android with the installed game's Live2D resources downloaded. Uses `adb`; `--inspect` additionally requires UnityPy. It never changes device settings, installs an APK or scans unrelated app data. It stops if source files changed and preserves existing downloads. Successful files are hash-checked and skipped on resume. Bundles above 64 MiB are refused for deliberate review. A partial transfer can be retried.

Edit `candidates.json` to choose known asset names/titles; do not bulk-download every skin. The current sample plan contains Belfast, Atago and Ägir. Files live only under the requested build directory and are not committed.

This device route automates source intake and inspection; Unity component → Cubism reconstruction remains separate. The public-viewer route below supplies complete model directories for the new offline Live2D adapter. Blue Archive's Spine renderer cannot decode `.moc3`.

## Public viewer route (September 2026)

The [Nagami viewer](https://azurlane.nagami.moe/live2d-viewer) exposes complete model3 directories and a separate [Spine viewer](https://azurlane.nagami.moe/spine-viewer). These are third-party mirrors of game assets, not official wallpaper downloads. `fetch-viewer.py --output <workspace>/models <skin-id>...` retrieves only explicitly named Live2D models, textures, motions and physics. It rejects external/traversing references, limits each response to 64 MiB, writes atomically and records hashes/source URLs. Existing files are reused; inspect their receipt before treating a cached download as trusted.

`wallpapers.json` is the reviewed 13-model operator plan: nine Live2D outfits and four Spine models. Original game textures are rendered at 4K; this is not AI-upscaled or native 4K detail by implication. Only the authored idle is exported, without voice lines, interactive gestures or Unity-only effects.

### Prepare selected sources

```sh
python3 scripts/azur-lane/prepare.py --plan scripts/azur-lane/wallpapers.json \
  --live2d-root build/azur-render --spine-root build/azur-spine \
  --metadata build/azur-wishlist/prepared-metadata
```

This caches the selected catalog records and complete declared model files. Use a new metadata directory when checking a newer catalog revision. It does not install dependencies or supply the proprietary Cubism Core.

### Prepared local workspaces

- `build/azur-render`: Live2D. Copy the files from `live2d/`, run `npm ci`, then bundle `render.js` and `../media-batch/fast-export.js` with the pinned esbuild. Supply Cubism Core from its upstream distribution or the viewer; its license is separate and it is not committed here. `catalog.json` comes from the viewer's `l2d_mapping.json`; `viewer-configs.json` combines the selected `skins/<id>.json` records. Download the referenced `bg/star_level_bg_<id>.png` files into `backgrounds/`.
- `build/azur-spine`: copy `spine/render.js` and `spine/cameras.json` (the renderer imports the recipes, so bundling fails without it), and use the media-batch dependency lock and HTML/fast-export sources. Each `models/<id>/model.json` is the viewer's `models/<id>.json`; retain every declared layer, atlas and texture beside it. Base Vanguard requires both layers. The adapter currently supports Spine 3.8 and no external image/effect layers; review anything outside that subset separately.
- Compile `scripts/media-batch/Render.swift` and `Encode.swift` into `render` and `encode` in each workspace. Both use AppKit/WebKit and require a macOS GUI session. All network access during rendering is loopback-only.

The Live2D adapter disables automatic pointer, blink and breath behavior so authored animation controls the result. It advances three idle cycles for physics warmup and then samples monotonically at 60 Hz. The scene period is rounded to the nearest frame; a loop flag and warmup alone do not establish a seamless boundary. Inspect first/middle/last and seam metrics before import.

### Export

### Camera recipes

`spine/cameras.json` holds `[zoom, cx, cy]` per asset, and `live2d/cameras.json` a zoom scalar. Both take the same per-animation object form as the lobby renderer, since a recipe is framed against the posed skeleton and is only valid for the animation it was tuned on.

The spine adapter needs these more than the lobby one does. Skeleton bounds cover the whole rig including transparent effect padding, so fitting bounds alone leaves a character-only model small inside the renderer's `0x18202b` background — `hu`, `makesi` and `qianwei` were 68%, 56% and 64% background before they were calibrated. Anything without a recipe falls back to that bare fit, so a newly prepared asset needs one before it is worth exporting.

Use `media-batch/calibrate.py` rather than editing a recipe and exporting to find out:

```sh
python3 scripts/media-batch/calibrate.py --workspace build/azur-spine \
  --asset models/<id> --stem <id> --animation normal --solve
```

It reports the worst matte over frames spread across the loop, writes previews, and restores the workspace's copy afterwards; commit the recipe you chose here. Remove matte, but keep any bleed margin the artist painted past the composition — narrower displays crop it usefully, and the pipeline README explains why that is not the same thing as a dead edge.

After building the workspaces, run `python3 scripts/azur-lane/previews.py build/azur-render final-previews` and repeat for `build/azur-spine`. This writes 960×540 images and metadata. Review framing before export; existing previews are skipped, so use a fresh directory after changes (and promote reviewed metadata to `final-previews`). Then:

```sh
python3 scripts/azur-lane/export.py \
  --plan scripts/azur-lane/wallpapers.json \
  --live2d-root build/azur-render --spine-root build/azur-spine \
  --output "$HOME/Pictures/Wallpapers/Azur Lane/Animated" \
  --job build/azur-wishlist/export
```

The runner serializes its plan, retains per-model logs, verifies every decoded frame, and publishes HEVC/poster/provenance files. Completed output hashes are checked on resume; an unfinished temporary video requires inspection rather than silent replacement. It never invokes Modal or changes the Library. Use a new job and output directory after changing assets or camera recipes.

Run `media-batch/verify.py --root build/azur-wishlist --job-name export` for diagnostic strips. Import approved media through the native Library panel after visual review. Archive complete model folders and provenance to the existing Drive sync root; local copy hashes do not prove cloud upload.
