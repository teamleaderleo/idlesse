# Fireflies default cost

2026-09-09: paired 12-second desktop qualification runs on the same two-display
Mac, with the ordinary wallpaper paused, compared the bundled scene with and
without its full-frame bloom effect. Both lifecycle cycles passed.

| Configuration | Mean GPU ms/frame, display 1 / 2 | Playing process footprint |
| --- | --- | --- |
| Full-frame bloom | 42.75 / 43.29 | 621 MiB |
| Particle shader's radial glow only | 4.32 / 6.73 | 461 MiB |

These are command-buffer GPU timings, not display FPS or energy measurements.
The qualification process reported zero presentation callbacks, so this run
cannot establish visible cadence. The cheaper default deliberately removes the
extra broad bloom; authored effects and the general compositor are unchanged.
Apply the same default to Library and Studio samples.

Local raw reports: build/fireflies-stutter-baseline.json and
build/fireflies-stutter-no-bloom.json (not committed).
