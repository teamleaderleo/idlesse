# Local verification — 2026-09-08

The optimized arm64 saver is installed and selected on macOS 26.6.2. Its signature
verifies. The installed preview displays the configured images.

## Verified in the actual host UI

- Options opens an editable Idlesse Settings panel, captured directly by the UI tool.
- A duration change from 5 to 6 seconds survived restarting System Settings.
- The original 5-second value was restored and verified after another restart.
- Choose opens a folder picker attached to the panel, initially at the saved folder.
- Choosing that folder and saving succeeds; the installed preview renders images.
- Save/Cancel/Choose fit within the window margins, confirmed visually and by the
  executable layout smoke test. Decoder tests pass as well.

## How to see it

Use the System Settings app target in the native UI tool. On a fresh Settings
launch: Wallpaper → Screen Saver → Options. The nonactivating NSPanel appears
in that target's accessibility tree, with readable fields, buttons and a screenshot.
Direct attachment to legacyScreenSaver's bundle ID still times out. After saving,
repeated automated Options clicks can fail to reach configureSheet; restarting
System Settings and its Wallpaper settings extension restores reliable access.
This is an unresolved automation/host routing issue, not proof every Options
click works for users. No broad screenshot permission was added.

For a local fallback, run `./build.sh capture-settings`, then click Options.
The saver consumes the marker and replaces `idlesse-settings.png` and
`idlesse-settings.json` in its container's Data/tmp directory. These contain only
Idlesse's own rendered settings and window/control metadata, including the selected
folder path. They are never uploaded. This render can omit native compositor
layers and does not prove on-screen visibility; prefer the actual UI screenshot.
`./build.sh clear-capture` removes the artifacts and pending request.

## Changes behind the verification

Settings uses a key-capable nonactivating panel at floating level, rather than
requiring the extension to activate a normal window above the screen-saver layer.
The folder picker is an attached sheet; dismissing standalone settings closes the
reusable panel. Rows account for content insets rather than overflowing the window.
Detached saver views stop timers and release images and their folder index.

Still unverified: locked/fullscreen idle activation, multiple monitors and long-run
memory/energy behavior. The existing one-hour idle activation setting is preserved.

### Additional resource cleanup

Random playback now computes each path's shuffle score once per cycle instead of
recomputing it during every sort comparison. The score, tie-breaker, and ordering
are unchanged. Slideshow restarts release both decoded images before scanning the
folder. The local diagnostic log resets when the next entry would exceed 256 KiB.
These changes passed a release build, decoder checks, and the settings layout
smoke check. Whole-process memory savings have not been measured.

### Measured performance and ergonomic controls (8 September)

The installed settings window was visually checked after installing the new build:
Pictures/Pace/Presentation sections, three timing presets, and existing 5-second /
2-second preferences were present. The preview's pause/next behavior passed both
interactive checks and an eight-cycle production lifecycle test. Invalid timing
showed an attached error sheet without saving. Added normal Edit menu shortcuts
to the standalone preview. Decoder and canvas color/geometry checks passed.

See [performance measurements](performance-2026-09-08.md) for actual installed-host
and preview memory, synthetic stress results, and the explicitly analytical
competitor cache model. The experimental rendering change was rejected.
