# Importing a new wallpaper

One page for "I have a character I want in Idlesse". The per-pipeline detail
lives in `scripts/media-batch/README.md` (Blue Archive lobbies) and
`scripts/azur-lane/README.md` (Azur Lane); this is the order to do things in
and the checks that stop the expensive mistakes.

## Which pipeline

| Source | Pipeline | Restored? | Costs money? |
| --- | --- | --- | --- |
| Blue Archive lobby (Spine) | `scripts/media-batch` | yes, Real-ESRGAN on the texture sheets | yes, one Modal GPU job per new sheet |
| Azur Lane Live2D (`.moc3`) | `scripts/azur-lane`, `live2d/` adapter | no, original textures at 4K | no |
| Azur Lane Spine | `scripts/azur-lane`, `spine/` adapter | no, original textures at 4K | no |

Blue Archive's Spine renderer cannot decode `.moc3`, and the Live2D adapter
cannot read Spine skeletons. The source decides the pipeline; there is no
shared renderer.

## The five gates

**1. Get the assets.** Blue Archive sheets go to
`build/ba-export-study/assets-pc/<Stem>/` as `.skel`, `.atlas` and `.png`.
Azur Lane comes through `fetch-viewer.py` and then `prepare.py`, which caches
the declared model files into the right workspace. Nothing is committed.

**2. Calibrate the camera. This is the gate that matters.** Every expensive
mistake so far has been a camera nobody looked at:

- A recipe is read from the **posed** skeleton, so it is only valid for the
  animation it was tuned on. One tuned on an intro pose will not frame the
  idle; it will put the character in the corner behind black bars.
- Skeleton bounds include transparent effect padding, so fitting bounds alone
  leaves character-only models small inside the renderer's background colour.
- Framing must hold across the **whole loop**. Characters sway; a recipe that
  covers the frame at `t=0` can bar a second later.

```sh
python3 scripts/media-batch/calibrate.py --workspace <workspace> \
  --asset <asset path> --stem <stem> --animation <animation> --solve
```

Then copy the recipe it prints into the tracked `cameras.json`
(`scripts/media-batch/cameras.json`, `scripts/azur-lane/spine/cameras.json`,
or `scripts/azur-lane/live2d/cameras.json`) and rebuild the workspace bundle.
Look at the preview: `--solve` only guarantees the frame is covered, not that
the crop flatters the character. Prefer the character large; background is
what you crop away.

**3. Render.** `run.py` for lobbies (restores once, caches, resumes; use
`--port 0` if something already holds the default port), `export.py` for Azur.
Both refuse to overwrite a finished output and both verify every decoded frame
against the authored loop length before publishing.

**4. Verify.** `verify.py --root <root> --job-name <job>` writes loop-boundary
diagnostics and **exits non-zero on dead edges**, which is what a bad camera
looks like from the outside. `pipeline.py` runs it with `check=True`, so a
misframed export cannot reach the archive step. Read the seam number next to
the first-step number: a seam near one frame of motion is a clean loop; a seam
much larger than a frame step is a visible jump.

**5. Import and archive.** Import through the Library panel. The Library stores
a security-scoped bookmark to the file path, so re-exporting to the same path
is picked up with no reimport and no thumbnail to invalidate. `archive.py`
mirrors video, provenance, poster and a source bundle to the Drive sync root;
it refuses a destination whose hash differs rather than overwriting, so clear
a superseded copy deliberately.

## Things that have bitten us

- **Restoring is not always worth it.** Effective sampling decides. Izuna
  renders at 1.73 restored texels per output pixel — already oversampled, so a
  larger restore would be discarded at the downsample. Check the magnification
  before paying for a bigger upscale.
- **A stale `mean_diff 0.00` reading.** Measuring motion against frame 0 across
  a whole clip catches slow scene-wide drift and reads as motion. Compare
  consecutive frames instead, and use a region that holds still as a control.
- **Colour channels clip.** Measuring a warm sunset on the red channel shows
  nothing because red is pinned at 255; measure across a gradient's own axis on
  a channel that is not clipped.
- **Only the authored animation plays.** A model can ship separate motions for
  scene effects: Perseus keeps her falling petals in `effect`, so exporting
  `idle` alone freezes them. Check the motion list for anything the idle does
  not drive, and note that two motions of different lengths may have no short
  common loop.
