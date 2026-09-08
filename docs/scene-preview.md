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
color parity remain separate compositor promotion gates.

## First editing controls

Select a layer in the right inspector and edit X/Y, scale, rotation, or opacity.
Press Return to apply. Reset Changes restores the scene loaded before the first edit.
Add an image/video or a gradient with the layer controls (two layers maximum).
New layers start centered at 60% scale. Bring Forward / Send Backward changes drawing
order while keeping the same layer selected. Remove keeps at least one layer.
Drag anywhere in the canvas to move the selected layer’s outline; release commits
its position. The outline previews the move without rebuilding players on each mouse
event. Edits rebuild the renderer, so videos restart once when the edit is applied.
Scale and rotation remain numeric controls; there are no resize/rotate handles yet.
Unsaved drafts suspend package watching and disable Use on Desktop. Opening another
scene or closing asks before discarding edits.

Save a Copy exports a new v2 package with its media, validates it, and opens that copy.
Existing destinations are never replaced. Source files stay untouched. Media copies
can consume additional disk space; this is not a cloud/offloading workflow. Export
runs away from the main thread and removes staging files on failure. Imported media access is retained for the draft and released when it is no longer
needed. Export preserves layer order and transforms.

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

## Live presentation readout

The preview samples successful Metal drawable presentations once per second, using
`MTLDrawable.addPresentedHandler` and excluding zero/invalid presented timestamps.
The readout counts displayed drawables, not render requests or unique video frames.
Counter storage is constant-size and protected for callback-thread access. The UI
sampling timer stops while paused/hidden/minimized/closed or displaying static content.
Native AVPlayerLayer playback and multi-layer standard rendering report unavailable
rather than inventing a combined frame rate.

The experimental compositor skips GPU submissions when neither a video texture nor
scene geometry has changed and no procedural gradient is present. Video polling
still follows the requested cadence; no CPU/energy reduction is quantified yet.
Gradients continue to animate at the selected cadence. Pending video changes are
retained when no drawable is available so a frame can be retried on the next draw.

2026-09-08 live development-build observations on the reported 160 Hz screen:
Aurora showed 84–85 presented fps in the standard path and 72 in a later unified
compositor sample. These are short UI observations under ongoing desktop activity,
not controlled comparisons or evidence that one renderer is faster. Neither sample
establishes sustained 160 fps. Build and wallpaper/GPU smoke tests passed, including
counter rejection of invalid timestamps and elapsed-time sampling/reset checks.
The 4K Evelyn illustration video subsequently showed 58–60 presented fps with Match
Display still at 160 Hz. Pause changed the readout to its idle state; the preview
was left paused. Loop-boundary smoothness and controlled energy measurements remain
outstanding.
