# Resumable lobby restoration batch

This is an offline operator tool, not a shipping renderer. It restores texture sheets once, adjusts atlas pixel coordinates, then renders authored Spine idle loops. It does not upscale thousands of video frames.

The default plan covers Karin (School Uniform), Reisa and Yuzu (Maid). `plans/plan-01.json` through `plan-06.json` cover 76 additional reviewed wishlist scenes. Sources are existing Japan Windows assets; outputs are restored 4K60, not native 4K detail. Review candidates and framing before adding them to a plan.

## Existing workstation

```sh
python3 scripts/media-batch/run.py \
  --root build/ba-export-study \
  --output "$HOME/Pictures/Wallpapers/Blue Archive/Live2D Restored"
```

Requires authenticated `modal`, FFmpeg, and the prepared renderer workspace. A single L4 function handles all sheets, with one-container limit, 900-second timeout, no automatic retries, and a two-second idle shutdown. GPU use is billable against the account's credits. No recurring cloud service is created.

State and per-stage logs live in `build/ba-export-study/batch-2026-09-10`. The runner locks the batch, fingerprints source files, refuses changed inputs/untracked outputs, skips completed hash-verified exports, and stops on a failed stage. It verifies full decoded frame counts and authored loop duration before publishing a video. Re-running the command resumes. A cloud failure without a complete returned archive may require rerunning restoration; the pipeline never silently retries a billable job.

Outputs: HEVC MP4, 1024-wide JPEG, and source/hash/measurement JSON. Visual review and Library import remain explicit final steps: never promote a black, cropped or incomplete render solely because FFmpeg accepted it.

## Rebuild render workspace

Copy `Render.swift`, `Encode.swift`, `render.js`, `cameras.json`, `fast-export.js`, `index.html`, `package.json`, and `package-lock.json` into a dedicated build workspace. In that workspace:

```sh
npm ci
node_modules/.bin/esbuild render.js --bundle --outfile=render.bundle.js
node_modules/.bin/esbuild fast-export.js --bundle --outfile=fast-export.bundle.js
swiftc Render.swift -o render -framework AppKit -framework WebKit
swiftc Encode.swift -o encode -framework AppKit -framework WebKit
```

Place extracted sources under `assets-pc/<asset-id>/`. No game assets are committed. The renderer requires a logged-in macOS GUI session even though it presents no desktop window.

The runner owns a localhost-only HTTP server on port 18763 for the duration of exports and shuts it down afterward. Use `--port 0` for an ephemeral port. A busy fixed port fails rather than interrupting someone else's server.

The default encoder captures the WebGL canvas directly through WebCodecs and muxes HEVC using Mediabunny. Each frame has an exact 1/60-second timestamp; it does not record wall-clock playback or create a JPEG per frame. A nonce-protected loopback receiver accepts the finished MP4. Limits are 3840×2160, 5,400 frames (90 seconds), and 512 MiB per encoded file. The MP4 is buffered in memory during muxing; this is not a constant-memory streaming encoder.

The native host stops after 120 seconds without progress or 30 minutes total. Jobs sharing a workspace serialize encoding through `.media-encoder.lock`. `run.py --encoder frames` selects the older JPEG/FFmpeg path; `--frame-asset ID` selects it for a specific asset. The runner attempts that local fallback once after a WebCodecs failure, without repeating GPU restoration. Full VideoToolbox decode checks dimensions, cadence and every frame before publication.

`run.py --encoder x265` encodes 10-bit HEVC with libx265, in full range with BT.709.
`encode_x265.py` loads the page through the same `encode` host. The page reads
each frame's raw pixels and POSTs them to a loopback receiver, which feeds FFmpeg
directly, so frames are never PNG-compressed or base64-encoded. It returns
per-stage timings as `stageSeconds`. Drawing and readback take about 70 ms per 4K
frame, so x265 sets the pace: about 2–3.5 frames per second with its lookahead
spread over several threads (the default single lookahead thread halves that).
`ingest.py` uses x265 by default; `--fast-encode` goes back to WebCodecs.
`IDLESSE_X265_JOBS` lets several exports share a workspace. Each x265 needs about
2 GB, and on a Mac already deep in swap, two at once stalled completely, so
batches here run one lobby at a time.

The difference shows in soft gradients under translucent layers, such as Hina's
window glow. Both hardware routes, 8-bit and Main10, cut those gradients into
contour bands and blocks at 40 Mbit/s. x265 keeps them close to the lossless
render at a lower bitrate. A half-float render with dithering added little once
encoded and changed additive highlights, so the renderer still blends in 8 bits.

Camera recipes live in `cameras.json`, as `[zoom, cx, cy]` under the skeleton stem. A recipe is framed against bounds read from the *posed* skeleton, so it is only valid for the animation it was tuned on: reusing one across animations drops the model out of frame behind black bars. Where a stem needs more than one, give it an object instead of an array, mapping animation names to recipes with `default` covering the rest:

```json
"CH0179_home": {"default": [2.0, 0.93, 0.33], "Start_Idle_01": [2.3, 0.22, 0.27]}
```

The camera actually used is recorded per export in `.source.json` and `state.json`. Akari uses both foreground and background skeletons, so its plan covers the complete background loop plus integral foreground loops. Saved video checkpoints deliberately do not regenerate just because renderer code changed. `verify.py` exits non-zero when an export shows more than 3px of renderer matte on any edge, at full resolution and worst across the sampled frames; `--allow-bars` downgrades that to a warning. It measures line by line, so a wedge or a strip down part of one edge fails as surely as letterboxing does, and it looks for both renderers' clear colours, black and the Azur adapter's `0x18202b`. An earlier version only failed an edge when a whole row or column was matte, checked a 512px downscale, and looked only at the first frame; it passed 40 of 117 exports with visible gaps, including Ibuki's 106px strip, which `calibrate.py --solve` had reported as clean for the same reason. The colour tolerance is deliberately tight (3): a clear colour survives encoding almost exactly, while very dark painted texture does not, and a looser tolerance misread Sakurako's shadowed stone as a 293px bar and five other dark scenes as matte.

### Calibrating a camera

Do not hand-edit a recipe and pay for an export to find out whether it worked. `calibrate.py` renders against a workspace and reports the matte:

```sh
# what the current recipe does
python3 scripts/media-batch/calibrate.py --workspace build/ba-export-study \
  --asset assets-ai-batch/<id> --stem <Stem> --animation Idle_01

# find one that covers the frame, starting from whatever is configured
python3 scripts/media-batch/calibrate.py --workspace build/ba-export-study \
  --asset assets-ai-batch/<id> --stem <Stem> --animation Idle_01 --solve

# compare framings by eye before committing to one
python3 scripts/media-batch/calibrate.py --workspace build/azur-spine \
  --asset models/<id> --stem <id> --animation normal --sweep 1.6 2.2 2.8
```

It works against any workspace holding a `render` binary and a `cameras.json`, so the same command serves the lobby and both Azur adapters. It writes preview PNGs and restores the workspace's `cameras.json` afterwards: copy the recipe you chose into the tracked file yourself.

Two things it is deliberately strict about. It measures several frames spread across the loop and reports the **worst**, because characters sway and a recipe that covers the frame at `t=0` can leave a gap a second later — that is exactly how barred exports have passed review. And zero matte only means the frame is covered, never that the crop is good; where the character sits in frame is a judgement call, so look at the preview.

### Matte is a defect, bleed is material

These look identical to the edge check and want opposite treatment.

**Matte** is the renderer's own background showing through because the recipe does not cover the frame. It is always wrong, `verify.py` fails on it, and `--solve` exists to remove it.

**Bleed** is low-detail margin the artist painted past the intended composition so that a crop has somewhere to go. It is dark or plain, so it reads like matte and the edge check cannot tell them apart — it measures uniformity, and bleed is usually dark but not uniform. Only looking at the frame distinguishes them.

Do not crop bleed out at export to tidy a frame. Exports are 16:9 and displays are not: a 16:9 frame filling a 1.545 panel is trimmed 13% on the sides, which spends the bleed and lands on a good composition for free. Cropping the bleed away at export removes that margin from every narrower display, which is a real regression in exchange for a tidier 16:9 frame. Hina was cropped this way and reverted for exactly this reason; her camera keeps the bleed deliberately.

So the rule is asymmetric: **remove all matte, keep the bleed.** Frame for the widest display in use and let narrower ones spend the margin. Where a wide panel then shows bleed it cannot crop, that is a display-side crop to fix (#96), not a recipe to re-cut — one baked frame cannot be right for two aspects at once, because the narrow display's good view is a crop of the wide display's.

### Framing in the app

For any imported picture or video, Library → More… → **Adjust Framing…** (or
Wallpaper → Adjust Framing of a File…) opens the frame with a crop box, the
focus point, picture adjustments, and a dashed outline of what every connected
display actually shows. Save writes the same `<name>.framing.json` described
below, and reloads the desktop once if that file is on it. Nothing is
re-exported. The editor warns when a crop enlarges the picture well past its
uncropped fit; that crop wants a re-rendered camera instead of a sidecar.

Use `measure-bleed.py` when the edge is too subtle to place by eye.

### Measuring the bleed

Do not eyeball the margin. `measure-bleed.py` profiles each edge across the
loop and reports where the composition actually ends:

```sh
python3 scripts/media-batch/measure-bleed.py \
  "$HOME/Pictures/Wallpapers/<collection>/<Name>.mp4" --edges left,right
```

It prints a brightness profile inward from each edge and lists candidate
boundaries -- every strong step, with its size and the margin it would imply.
It deliberately does not pick one. Interior art detail produces steps as large
as a band edge does, so an automatic choice is wrong about as often as it is
right; an early version of this script confidently reported Haruka's margin as
849px, which was a highlight in the middle of her dress.

Read the profile: **a flat plateau is margin, a smooth ramp is painted art.**
Bleed shows up as a staircase of constant-brightness bands, because the margin
is the composition's edge extended rather than drawn. A hard dead edge is
unmistakable -- Haruka's black left edge steps by +105 where interior detail
never exceeds 52. Then pass your choice back:

```sh
python3 scripts/media-batch/measure-bleed.py "<...>.mp4" \
  --edges left,right --margin right=256 --margin left=9 --write
```

That writes `<name>.framing.json` beside the media. It needs only ffmpeg and
the standard library, so it runs outside the study venv, and it never touches
the video.

The reason to measure rather than guess is that a value which is merely *close*
does nothing useful. A margin declared slightly too small still leaves part of
the band on screen; declared far too large it starts eating composition on
every display. Confirm the geometry against the displays actually in use before
settling on a number.

### Adjusting a bright or flat scene

Some lobby art is simply painted bright: Seia's sunlit bedroom averages 224 of 255 and plays back exactly as rendered. Before adjusting anything, check that brightness is the art and not the file. An export whose colour tags are incomplete displays with lifted midtones, and `run.py` now fixes those tags before publishing, but older files may predate that.

Use the editor's sliders, or add `tone` to the sidecar next to any framing. Every field is optional and 0 is neutral:

```json
{"bleed": {"right": 0.0029}, "tone": {"exposure": -0.45, "soften": 0.2, "contrast": 0.2, "saturation": 0.25}}
```

| Field | Range | Effect |
|---|---|---|
| `exposure` | -2 to 2 | stops of light, multiplied in linear light |
| `soften` | 0 to 1 | rolls highlights off; the peak falls toward 0.82 at full strength |
| `contrast` | -1 to 1 | around mid-grey |
| `saturation` | -1 to 1 | -1 is greyscale |

The wallpaper applies them to video at playback in Core Image's colour-managed working space, and the file is not touched, so deleting the key restores it. Overexposed art usually wants exposure down with a little contrast and saturation back, rather than heavy softening alone: softening past about 0.4 greys the whites and desaturates pastels. Stills are not adjusted yet.

Use the existing Drive sync folder for archiving originals/restored texture bundles and final clips. Verify copy hashes before deleting disposable local intermediates. Sync-folder presence alone does not prove remote upload completion. Keep Library-referenced playback files until a bookmark-aware move/relink is performed.

Dependencies retain their upstream licenses, especially the Spine runtimes. This operator harness does not establish redistribution rights for those runtimes or game assets.

Tests: `python3 scripts/media-batch/test_batch.py`.

After exports, run `verify.py --root build/ba-export-study` using the study venv (Pillow). It creates first/middle/last strips and loop-boundary diagnostics for review. Then `archive.py --root build/ba-export-study --drive "<existing Drive sync root>/Idlesse"` copies and hashes videos, provenance, posters and one source/restoration archive. It does not claim cloud sync or delete playback files.

## Importing one lobby

`ingest.py` takes one scene from source to installed wallpaper:

```sh
python3 scripts/media-batch/ingest.py hanako_home                  # already in assets-pc
python3 scripts/media-batch/ingest.py ~/Downloads/lobby.zip --title Someone
python3 scripts/media-batch/ingest.py --fetch ch0400_home --title Someone   # BA-AD download
python3 scripts/media-batch/ingest.py hanako_home --crop 0.1 0 0.8 0.8 --preview
```

It renders a free preview from the original textures and measures matte across
the loop before anything else; `--preview` stops there, and matte stops the run
unless `--allow-matte`. `--fit` renders the whole scene zoomed out, marks the matte reachable from its edges in every sampled frame, and frames the largest box clear of it; the step solver only runs if that still leaves matte. The solver alone zoomed Hoshino (Swimsuit) to 1.81 and cut off her head chasing a notched corner, where the painted-area box frames the whole scene at 1.26. When the painted area is taller or wider than the frame there is room to choose, and `--fit-toward X Y` says which way to lean: `0.5 0` keeps the top of a tall scene, where a lobby's face usually is (Saki's sits above the centred box). It also runs the camera solver on the preview first, so a
lobby whose art leaves a wedge uncovered is zoomed just enough to cover the
frame; `--camera Z CX CY` pins a recipe instead. `--trim-edges` keeps the camera and
writes the matte depth on each edge into the sidecar as bleed, up to 15% of an
edge. Prefer it for thin strips: a narrower display already crops more than a side
strip, so it loses nothing, while a camera zoom removes that art everywhere. Most
lobbies' matte is a strip of a few percent; a deep wedge or stray spare pose still
wants `--fit`. `--crop X Y W H` is a unit box of the current frame to
keep, and becomes the camera. Upscaling is the only paid step: it runs only for
a lobby never upscaled before, is quoted from the timings of past runs and
Modal's list prices (a typical lobby is a few cents; the 15-minute cap bounds
the worst case), and needs a yes or `--yes`. Everything else is local.

Upscaling is billed per job, and most of a single lobby's cost is container
startup. `--upscale a b c` upscales several lobbies in one job instead, so later
imports of each are free; all 34 lobbies still unupscaled here quote at about
$0.18 together against $1.61 one by one. It refuses work estimated past 600
seconds, leaving the 15-minute cap room.

Lobby art often draws a 1px dark outline right at a transparent silhouette, so
upscaling its alpha keeps every source pixel as a stair step. The upscale job
also runs each texture's alpha through the model into `assets-ai-masks`, and
`smooth_edges.py` uses that mask only where it stays close to the Lanczos alpha
(a step, not a reshape) and not in dense soft transparency such as lace or
smoke, where it hardens detail. Exports use it by default (`--edges smooth`,
rendered from `assets-ai-smooth`); `--edges original` keeps a lobby's edges as
painted, and a re-render keeps whichever its receipt records. Lobbies upscaled
before masks existed export with original edges rather than paying again.

`--update-names` caches lobby names from SchaleDB's public student list, whose
`DevName` is the lobby code (`CH0064` is `ch0064_home`); it matched 41 of 43
hand-chosen titles, the other two only adding a suffix. `--list` then names every
lobby, and recognises older installs by file name and by text receipts.

In the app, **Wallpaper → Import Lobby…** does the same through this script. It
lists every extracted lobby with its state (installed, free, or the upscale
price), previews the selection, offers **Fit Camera** when the preview shows
matte, and imports with the exact camera it previewed, then adds the result to
the Library. An upscale is named with its estimate and its cap in a
confirmation before the window passes `--yes`. Folder or ZIP… copies a lobby into
`assets-pc` and previews it the same way. The app finds the script through the
paths `ingest.py` records in its defaults, or, for a build inside a checkout,
beside the build. `--list` and `--json` are the machine-readable forms it uses.

An install from Terminal joins the Library too. `ingest.py` leaves a one-line
note in `~/Library/Application Support/Idlesse/Library/Inbox/`. Idlesse watches
that folder and adds the file itself, or refreshes its preview if the Library
already has it, as soon as it is running. Pass `--no-library` to skip the note.
Never write Library bookmarks from another process. A security-scoped bookmark
resolves only in the app that minted it, and the Library shows "Preview unavailable" for
it until the app re-mints the bookmark.

### Re-rendering a crop

A crop drawn in **Adjust Framing…** is a display-side zoom, so it enlarges the
video. To keep full detail, render the crop as the camera instead:

```sh
python3 scripts/media-batch/ingest.py --reframe ".../<Title>-Restored-4K60.mp4" --from-sidecar
```

or press **Re-render Camera…** in the editor, which runs exactly that. Azur Lane
exports re-render the same way: the receipt's `kind` picks `build/azur-spine` or
`build/azur-render` beside this workspace and `scripts/azur-lane/export.py`
renders them from their original textures, so it is always local. A Live2D crop
is stored as a whole-stage `view`, so the background is cropped with the model. It reads
the camera the export was made with from its `.source.json`, composes the crop on
top, exports locally from the existing upscaled textures, archives the old file
in `superseded-<date>/`, renames the new file over it atomically (a playing wallpaper keeps the old inode until it reloads), and removes the crop box and
focus from the sidecar while keeping adjustments. The app never passes `--yes`,
so a scene that still needs upscaling stops at the quote. The button appears
once `ingest.py` has run on this Mac, because each run records its location in
the app's defaults. New cameras are written to both the workspace and the
tracked `cameras.json`; commit the latter to keep them.

## One-command pipeline

`pipeline.py` chains restoration/export, diagnostic previews and Drive copying, stopping on failures. Completed video checkpoints are reused. Example:

```sh
python3 scripts/media-batch/pipeline.py \
  --root build/ba-export-study \
  --output "$HOME/Pictures/Wallpapers/Blue Archive/Live2D Restored" \
  --drive "$HOME/Library/CloudStorage/GoogleDrive-leoli.4u@gmail.com/My Drive/Idlesse"
```

It uses the workspace `.venv/bin/python` for Pillow-based QA, or `--qa-python`. The final human/agent checks are visual review and normal Library import. It does not mutate the running app's Library store behind its back or automatically spend money on a recurring schedule.

## Additional wishlist batches

Use `--plan /path/to/batch.json --job-name wishlist-01` with `pipeline.py` to process another bounded batch in the same prepared workspace. Each job has separate fingerprints, logs, state and Drive archive directory. Existing default job paths remain compatible. Only include visually reviewed source scenes; model filenames alone do not establish correct framing or an authored seamless loop.

```sh
python3 scripts/media-batch/pipeline.py \
  --root build/ba-export-study --port 0 \
  --plan scripts/media-batch/plans/plan-01.json --job-name wishlist-01 \
  --output "$HOME/Pictures/Wallpapers/Blue Archive/Live2D Restored" \
  --drive "$HOME/Library/CloudStorage/GoogleDrive-leoli.4u@gmail.com/My Drive/Idlesse"
```

`run.py --restore-only` prepares textures without starting video exports. Completed GPU restoration is checkpointed independently from video work. Import final MP4s through Library; do not include JPEG posters or provenance sidecars.
