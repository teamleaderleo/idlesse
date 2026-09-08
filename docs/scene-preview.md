# Scene Preview

Open **Scene Preview…** from the preview controls or Wallpaper menu (⌘O).
The separate workbench opens an image, video, or `.idlesse` package without changing
the desktop. A built-in Aurora scene makes it usable with no downloads.

- Pause/resume and compare Standard with Metal · Experimental.
- Opened packages hot-reload through SceneWatcher. Invalid metadata or an unplayable
  video keeps the previous preview; asynchronous renderer errors appear in the subtitle.
- Use on Desktop closes the preview and hands the source to the wallpaper host.
  The comparison control affects only the preview; the desktop retains its own renderer selection.
- Closing releases the renderer. Hidden/minimized previews, system sleep, and Low
  Power Mode pause playback. Opening Scene Preview stops the saver preview behind it.
- Resize completion rebuilds at the new image decode budget. Video playback restarts
  on resize or renderer switching; this is not a synchronized frame comparison.

Verified with native UI: open/close/reopen, standard and Metal Aurora rendering,
Jane Trust video, Evelyn Illustration 4K video in Metal, and the pause control.
Build, decoder/scene tests and wallpaper/GPU smoke tests pass. Energy and native-size
color parity remain separate compositor promotion gates. This is a preview workbench,
not yet a layer editor.

## Frame rate

The top-right frame-rate control is saved for both preview and desktop scenes:
Auto, 30, 60, 120, 160 fps, or Match Display. Match Display requests the screen's
reported maximum, including rates above 160 Hz. Moving the preview between displays
updates that request; desktop surfaces each use their own display. Fixed requests
are capped to the screen maximum. Changes update existing renderers without restarting
playback. Auto preserves the renderer defaults (30 for standalone gradients, 60 for
the experimental compositor); it is not yet an adaptive performance governor.

This controls generated/composited frames, not video interpolation. Standard video
playback continues at its source cadence. Metal may redraw the same decoded video
frame between source frames. Static scenes remain event-driven and power-related
pausing remains in effect.

The displayed Hz value is the screen's reported capability, not measured achieved
fps. Metal chooses a supported cadence and GPU load can reduce achieved throughput.
See [NSScreen.maximumFramesPerSecond](https://developer.apple.com/documentation/appkit/nsscreen/maximumframespersecond)
and [MTKView.preferredFramesPerSecond](https://developer.apple.com/documentation/metalkit/mtkview/preferredframespersecond).

Native UI verification: the connected preview screen reported 160 Hz. Selected
Match Display (160 Hz) on Aurora and verified the scene remained visible. This
verifies detection and selection, not sustained 160 fps presentation. Smoke tests
cover 160/240 Hz matching, fixed-rate clamping, Auto fallback, and updating the
standalone gradient's Metal frame-rate request.
