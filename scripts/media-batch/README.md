# Resumable lobby restoration batch

This is an offline operator tool, not a shipping renderer. It restores texture sheets once, adjusts atlas pixel coordinates, then renders authored Spine idle loops. It does not upscale thousands of video frames.

The checked-in plan covers Karin (School Uniform), Reisa and Yuzu (Maid). Sources are existing Japan Windows assets; outputs are restored 4K60, not native 4K detail. Review candidates and framing before adding them to a plan.

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

The previously task-local renderer sources and dependency lock now live here. Copy `Render.swift`, `render.js`, `index.html`, `package.json`, and `package-lock.json` into a dedicated build workspace; run `npm ci`, `npx esbuild render.js --bundle --outfile=render.bundle.js`, then `swiftc Render.swift -o render -framework AppKit -framework WebKit`. Place extracted sources under `assets-pc/<asset-id>/`. No game assets are committed.

The runner owns a localhost-only HTTP server on port 18763 for the duration of exports and shuts it down afterward. A busy port fails rather than interrupting someone else's server. HEVC streams directly from the renderer; no giant frame sequence is accumulated.

Use the existing Drive sync folder for archiving originals/restored texture bundles and final clips. Verify copy hashes before deleting disposable local intermediates. Sync-folder presence alone does not prove remote upload completion. Keep Library-referenced playback files until a bookmark-aware move/relink is performed.

Dependencies retain their upstream licenses, especially the Spine runtimes. This operator harness does not establish redistribution rights for those runtimes or game assets.

Tests: `python3 scripts/media-batch/test_batch.py`.

After exports, run `verify.py --root build/ba-export-study` using the study venv (Pillow). It creates first/middle/last strips and loop-boundary diagnostics for review. Then `archive.py --root build/ba-export-study --drive "<existing Drive sync root>/Idlesse"` copies and hashes videos, provenance, posters and one source/restoration archive. It does not claim cloud sync or delete playback files.
