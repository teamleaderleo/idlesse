# Refresh-rate investigation — 2026-09-08

Added a repeatable **Measure 10s** control to Scene Preview. It samples successful
presentations over elapsed wall time and averages GPU command-buffer execution time
from completed command buffers. It uses counters, not per-frame retained samples.
Changing scene, rate, screen or playback state cancels the measurement. This measures
the preview, not whole-system GPU activity, input latency, or energy.

On the reported 160 Hz display, the default MTKView-driven Aurora preview averaged
75.3 presented fps with 0.20 ms GPU time per frame over one sample. The GPU time is
well below the 6.25 ms refresh budget. This suggests investigating scheduling and
presentation rather than lowering shader quality; it does not isolate the cause.

API: [Metal GPU timing](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime).

A view-bound CADisplayLink experiment produced 102.5 fps / 0.28 ms GPU in its
first sample, then 83.2 fps / 0.32 ms in the repeat. The experiment preserved shader,
resolution and the two-frame GPU bound. These uncontrolled development-build samples
under ongoing desktop activity do not establish a reliable gain. The scheduler
experiment was reverted; both production drawing loops remain unchanged.

The retained measurement control makes the next comparison reproducible. Follow-up:
collect display mode, draw callback frequency, unavailable-drawable and in-flight
skip counts, then run repeated foreground/occluded samples with matched system load.
Do not lower image resolution or call the 160 Hz request an achieved frame rate.

Build and wallpaper/GPU smoke checks passed. Native UI exercised measurement start
and completion; GPU accumulator checks reject invalid timestamps and verify averaging
inputs. The preview minimum width increased to accommodate the extra control.
