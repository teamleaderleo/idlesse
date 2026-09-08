#!/usr/bin/env python3
"""Analytical bitmap costs, not measurements or emulation of another app."""
import json
print(json.dumps({
    "assumption": "Fully materialized 8-bit RGBA bitmaps; excludes decoder scratch, encoded data, GPU/host/allocator costs.",
    "warning": "NSCache may evict early; NSImage may decode lazily. These are capacity scenarios, not app RAM predictions.",
    "scenarios": [
        {"name": "Two 24 MP original bitmaps", "bytes": 2 * 6000 * 4000 * 4},
        {"name": "Two 3840x2560 fill bitmaps", "bytes": 2 * 3840 * 2560 * 4},
        {"name": "24 fully decoded 24 MP originals", "bytes": 24 * 6000 * 4000 * 4},
    ],
    "context": "ArenaFrameScreensaver ImageCache.swift declares NSCache.countLimit = 24. This models capacity only.",
    "source": "https://github.com/tiny-factories/arena-frame-screensaver/blob/main/ArenaFrameScreensaver/ImageCache.swift"
}, indent=2))
