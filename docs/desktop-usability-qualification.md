# Desktop usability qualification

Qualification checkpoint: app source `cb0ef06`, September 12, 2026.

| Requirement | Evidence | Status |
| --- | --- | --- |
| Coverage-rest reveal delay | DesktopRevealPolicy tests cover slow dispatch, duplicate request, success grace, failure; live Show/Restore exercised | Implemented; visible animation latency not measured |
| Menu strip enabled for ordinary videos | Shared renderer predicate; plain-image/video on/off smoke checks; existing Hina produced paired presentation timestamps | Verified |
| Menu strip synchronization | Display 3: 1,330 pairs, 1.06 ms mean absolute skew, 12.50 ms max, 2 missed copies. Display 1: 1,166 pairs, 3.96 ms mean, 16.67 ms max, 246 misses | Measured sample; not atomic |
| Thumbnail memory and refresh | Bounded ImageIO thumbnail path, coalescing and stale-result rejection smoke checks | Verified |
| Library navigation and preview isolation | Home/Library smoke, real Ichika video poster, manual chooser/cancel and current Hina state | Verified |
| Current playback controls | Live popover Pause/Resume and toolbar labels; playback restored | Verified |
| Native chooser ownership | Opens sheet, Cancel returns to Library; no legacy saver detour | Verified |
| Wallpaper/display preservation | Existing Hina remains active; no display configuration operations | Verified for this work |

Final checkpoint commands passed:

- `./test.sh`
- `build/Idlesse.app/Contents/MacOS/Idlesse --smoke-home`
- `--smoke-library` with an existing 4K60 Ichika video; includes composed-video poster
- `git diff --check`

The development app was rebuilt and relaunched after app edits. The wallpaper
surface screenshot showed the current Hina scene rendered correctly. The UI
capture returns individual windows; it did not capture the combined menu material
and wallpaper in one image. That is not proof of visual menu-bar parity.

## Remaining qualification

- Measure user-visible desktop-reveal animation latency, distinct from the logged
  Mission Control dispatch completion.
- Inspect combined menu material and desktop for crop/color continuity. Paired
  timestamps cannot detect spatial mismatch or macOS blur/refraction.
- Determine whether the larger missed-copy count on display 1 warrants a scheduling
  change. Do not increase decode work or force the desktop to wait for the strip
  solely to make the counters look better.

The measured skew is an observed limitation of the current two-window presentation
path, not evidence that macOS cannot support a different implementation. No claim
of zero hitch, atomic presentation, global FPS improvement, or energy improvement
is made. The long-running qualification goal remains open.

## Drawable-buffer trial

The menu strip now permits three drawables (previously two); the ready/request
queue remains bounded to one each. Only the narrow strip gains a buffer.
With the existing wallpaper, before/after samples were:

| Buffer count | Display | Paired frames | Missed copies | Mean absolute skew | Maximum |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | 3 | 9658 | 195 | 0.62 ms | 25.00 ms |
| 2 | 1 | 9066 | 2279 | 4.96 ms | 33.34 ms |
| 3 | 3 | 3725 | 57 | 0.80 ms | 25.00 ms |
| 3 | 1 | 3873 | 16 | 0.85 ms | 50.00 ms |

These are sequential, unequal-duration live samples, not controlled benchmarks.
The display-1 missed-copy ratio and mean improved markedly, but worst-case skew
increased; do not infer atomic synchronization or universally lower latency.
The main renderer does not wait for the strip and no additional decoder is used.
