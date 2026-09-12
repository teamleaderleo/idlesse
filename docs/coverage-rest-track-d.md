# Coverage rest — Track D qualification notes

Issue: #28, Track D

## Current behavior

Coverage rest remains opt-in through `coveragePauseEnabled`.

The monitor now uses a conservative state policy per display surface:

- enter rest at 95% measured coverage after 2 consecutive samples;
- resume at 85% measured coverage after 2 consecutive samples;
- hold the prior state inside that hysteresis band;
- discard a prior rest decision after an 8-second sampling gap;
- ignore whole-window alpha below 0.98;
- continue excluding the known Dock / Notification Center / Screenshot full-screen chrome entries;
- log every coverage sample, pending transition, and filtered-window counts to `/tmp/idlesse-state.log`.

The desktop qualification report now records each surface frame, whether coverage rest is active, submitted/presented frames, and accumulated GPU time/frames so a cover interval can be compared with an uncovered interval.

## Code-side observations

1. The old single 0.90 cutoff changed renderer state on one sample. A window resize or transient compositor entry near the cutoff could therefore pause/resume a display immediately.
2. `CGWindowListCopyWindowInfo` supplies window rectangles and whole-window alpha. It cannot prove that every pixel inside an alpha-1 window is visually opaque. Vibrancy, shaped windows, and transparent content remain a false-positive risk.
3. System UI needs explicit filtering because some system-owned windows publish large bounds that do not correspond to visible opaque coverage. Owner-name filtering is intentionally conservative and can produce false negatives as macOS UI processes evolve.
4. Per-display pause is already independent at the renderer surface: each `WallpaperSurface` has its own `covered` state and pauses only its renderer.
5. A false negative costs GPU. A false positive freezes a visible wallpaper. Thresholds and alpha filtering therefore favor false negatives.

## Real-desktop matrix

Run these with an animated/Metal scene and capture `/tmp/idlesse-state.log` plus the qualification JSON:

- bare desktop → active;
- one ordinary overlapping window at 40–80% cover → active;
- several ordinary windows exceeding the rest threshold → rest only after the second stable sample;
- fullscreen opaque app → rest, then resume after stable exposure;
- two displays with only one covered → only that surface rests;
- Mission Control → no false rest while the wallpaper is materially visible;
- Stage Manager, where available → no false rest from system-owned compositor chrome;
- explicit whole-window transparency below 0.98 → ignored as coverage;
- alpha-1 window with visibly transparent content → record whether the rectangle model produces a false rest;
- Dock, Notification Center, screenshot UI, menu bar/system chrome → no false whole-display rest.

For a timed report, launch the qualification harness twice with equivalent desktop actions, once with coverage disabled and once with `-coveragePauseEnabled YES`. During covered intervals, compare deltas in `submittedFrames`, `presentedFrames`, `gpuFrames`, and `gpuSeconds` for the affected display. A useful result should drive the affected renderer's frame/GPU deltas close to zero while leaving uncovered displays unchanged.

## Qualification status — 2026-09-11

This branch was prepared from `main` commit `46ea41b91a89c7c9e0a3f45f1dfef172d54ec727`. The execution session used for Track D has no logged-in macOS desktop or attached multi-display Mac runner, so fullscreen, Mission Control, Stage Manager, transparent-content, and GPU-savings claims remain unmeasured here.

That missing evidence keeps the feature experimental and off by default. The rectangle model has a known blind spot for alpha-1 transparent content; a real-desktop pass that shows false rests or trivial renderer/GPU savings should remove coverage rest instead of adding more compositor-specific exceptions.

## Verdict

**Keep experimental.** The transition policy is cheap and bounded, and the existing per-display pause path can produce a large renderer saving when the coverage signal is correct. Promotion requires a real Mac matrix with clean per-display behavior and clear GPU/frame deltas. Failure on either axis is a removal signal.
