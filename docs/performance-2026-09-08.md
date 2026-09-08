# Idlesse performance and usability check — 8 September 2026

We measured the running Mac and built a repeatable synthetic test. There is no
evidence yet for a general “faster/lighter than Apple” claim. Bounded decoded
dimensions remain useful, but are not a whole-process memory guarantee.

## Live measurements

Apple's `footprint` utility sampled every 10 seconds, for 20–30 seconds.
Values below are MiB (rounded); Activity Monitor may round differently.

| Process / state | Observed footprint |
| --- | ---: |
| Apple Flurry, existing process 98678 | 807 MiB |
| Installed Idlesse host 92797 | 297–453 MiB |
| Secondary legacy host 92796 | 23 MiB |
| Idlesse preview, paused | 66–69 MiB |
| Idlesse preview, playing, shipping renderer | 135 MiB |
| Idlesse preview, experimental direct renderer | 124–138 MiB |

The installed host was confirmed to have Idlesse.saver loaded. These are
observations of existing sessions with different rendering sizes, content and
process histories, **not a matched product benchmark**. Flurry was already running;
we did not simulate Apple's private code. The Apple Photos helper was not present
in this check. Idlesse's installed host numbers show why reporting only the
standalone/off-screen test would be misleading.

## Synthetic workload

Four deterministic 6000×4000 JPEGs with high-frequency RGB noise. 24 image loads,
six software-rendered crossfade frames each, into one 3840×2160 bitmap surface.
Each mode runs in a separate release-build process, with a fresh autorelease pool
per image. No user photographs are copied or uploaded. Fixtures are deleted.
The workload stresses decoding and resizing; it is not representative photography,
screen refresh timing, or a cold disk/cache experiment.

| Shipping renderer | Peak sampled physical footprint | Maximum RSS from time | Wall time |
| --- | ---: | ---: | ---: |
| Idlesse bounded decoding | 107.7 MiB | 819.3 MiB | 27.77 s |
| Generic full-resolution decoding reference | 42.4 MiB | 731.9 MiB | 26.29 s |

These runs did **not** demonstrate lower process memory from thumbnail decoding.
Physical footprint, resident memory, retained bitmap bytes and GPU memory are
different metrics. Sparse phase samples can miss transient peaks; maximum RSS
captures a different high-water mark. Other apps were running, and each condition
was run once, so small speed differences are not conclusions.

An experimental direct Core Graphics renderer was also tested: roughly 107.3 MiB
sampled footprint but 1235.2 MiB maximum RSS for bounded decoding. The reference
also rose to 1027.5 MiB maximum RSS. That experiment was **reverted** because it
showed no reliable benefit. The benchmark runner remains available for future work.

## Lifecycle and controls

Eight production saver start/stop cycles, 1-second display time and 0.2-second
fade, with isolated preferences and a 1920×1080-point off-screen view. Every cycle
also exercises pause, manual next while paused, and resume. Assertions verify
that the image does not advance while paused, manual next advances it, and the
retained image count is zero after stopping.

The initial run's stopped physical footprint ranged from 24.4 to 26.2 MiB;
this is a slight increase, not proof of leak-free long-term operation.
No on-screen rendering occurs in this lifecycle test. Full-screen locking,
multiple monitors, energy use and hour-long operation remain unmeasured.

## Competitor model

[ArenaFrameScreensaver's image cache](https://github.com/tiny-factories/arena-frame-screensaver/blob/main/ArenaFrameScreensaver/ImageCache.swift)
uses an NSCache count limit of 24 and loads images from encoded data. We modeled
bitmap capacity rather than installing or pretending to emulate that app:

| Assumed materialized RGBA bitmaps | Bitmap bytes only |
| --- | ---: |
| Two 24 MP originals | 183.1 MiB |
| Two 3840×2560 fill previews | 75.0 MiB |
| Twenty-four 24 MP originals | 2197.3 MiB |

This is arithmetic, **not measured competitor memory**. NSImage can decode lazily,
NSCache can evict before its count limit, and encoded data/rendering scratch/host
costs are excluded. See `Benchmarks/cache_model.py`.

## Reproduce

Build with `CONFIG=release bash build.sh`, then run
`python3 Benchmarks/run.py`. A mode can be selected with
`python3 Benchmarks/run.py lifecycle`. JSON samples and OS maximum-RSS/CPU output
are written under `build/benchmarks`; large fixtures and the temporary app are
removed in a finally block. Runtime is bounded per child. The benchmark does not
change the user's saver settings.

For comparable product measurements next, use the same display, image set,
duration, transition and cold/warm start procedure, multiple repetitions, and
include the entire host/GPU process tree. The current measurements are sufficient
to reject unsupported marketing claims and to catch lifecycle regressions.
