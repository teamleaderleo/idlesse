# Idlesse Studio

Open **Studio…** from the preview controls or Wallpaper menu (⌘O). Studio opens
images, videos, and `.idlesse` packages without changing the desktop. Aurora is a
built-in starter scene. Standard remains the default; Metal is an experimental
comparison renderer, independent of editing.

## Editing

The left list shows frontmost layers first. Select there or click a layer’s rectangle
on the canvas. Option-click cycles through overlapping layers; selection uses layer
bounds, not per-pixel alpha. Drag rows to reorder them. Scenes support up to 16 layers, two videos and four gradients. Eye and lock buttons control visibility and canvas editing; both are saved and undoable. Hidden media stays allocated but pauses. Layer type icons avoid decoding thumbnail copies.

Drag a layer to move it, its corner squares to scale it uniformly, or the circle
above it to rotate. Shift snaps rotation to 15°. With the canvas focused, arrow keys
nudge by one canvas point; Shift nudges by ten. Delete removes the selected layer
unless it is the last. Duplicate Layer (⌘D) is available within the scene resource limits.
Names, X/Y, scale, rotation and opacity are editable in the inspector; Return commits.

Use +/− or a trackpad pinch to zoom; scroll to pan. Fit restores the whole canvas.
Canvas manipulation previews an outline and commits once on release. Committed edits
preserve playback for transforms, opacity, names and ordering, including undo/redo. Canvas gestures preview these changes live and commit one undo action. Adding, removing or replacing content still rebuilds playback. Select a layer and choose **Group with Next Layer** to combine it with the layer
above it in drawing order. A group can be named, moved, scaled, rotated, faded,
hidden, locked, duplicated and saved. Group property edits preserve child playback;
creating a group currently rebuilds playback. Undo restores the separate layers.
Disclosure arrows expand groups. Child layers can be named, transformed numerically,
faded, hidden, locked, duplicated, removed, and reordered among siblings without
restarting their media. Adding a layer while a group is selected inserts it into
that group; otherwise it inserts beside the selected layer. Undo restores selection
and expands ancestors when needed. Canvas selection, move/resize/rotate handles,
and keyboard nudging also work on children through nested parent transforms.
Normal clicks select the frontmost child; Option-click cycles through overlapping
children and their groups. Hidden or locked ancestors block canvas interaction.
Picking respects group clipping and ellipse masks; it does not inspect image alpha.

**Ungroup** restores children when the group's transform, opacity and appearance
are at their defaults. It carries visibility and locking to the children. Styled
or transformed groups must be reset first: silently distributing group opacity or
removing a clipping canvas could change the image. There is no cross-group drag
reparenting yet.

**Appearance…** adds an ellipse mask, exposure (−2…2 stops), saturation (0…2),
and a vignette strength slider (0…1). Apply commits one undoable live renderer edit.
Vignette darkens the edges without changing alpha or the center, and costs no extra
render pass or texture. Scenes save as v6 with persistent layer IDs, v7 with controls,
v8 with time/pointer signals, or v9 with ordered modifiers.
**Bind…** links a selected layer property to a numeric control; **Controls…** adjusts
the generated sliders. Apply preserves playback and supports Undo. See
[the control format and current limits](scenes.md#numeric-controls-and-bindings-version-7).
The Bind sheet can multiply its result by an existing control. It authors one
multiplier; replacing a binding replaces its entire modifier stack. More elaborate
ordered add/multiply stacks can be edited in the package JSON.
A styled scene automatically uses Metal
in Studio and on the desktop; first switching from Standard restarts playback,
while subsequent appearance edits preserve the renderer. Plain scenes retain the
Standard fallback. There is no arbitrary effect graph yet.

## Scene transport

With Metal selected, **Time…** seeks to a scene time, sets playback speed from
0.1× to 4×, and optionally loops a start/end interval. Apply refreshes a paused
canvas without resuming it. Time and loop endpoints are limited to 0–86400 seconds;
loops must last at least 0.01 seconds. Seeking before the loop start lands on its
start; seeking at or beyond the end wraps into the interval.

Transport controls affect gradients and time-based bindings. Video players retain
their own position and speed unless Playback… enables experimental video following; this is not frame-accurate synchronization. Settings
belong to the preview session, survive scene edits, and are not exported or sent
to the desktop. Saved playback is available separately through Playback….

## Documents and saving

Raw media and Aurora start as untitled scenes. Save (⌘S) creates a new `.idlesse`
package. An opened package saves back to its source; Save As (⇧⌘S) creates a separate
package. Save As refuses existing destinations. New packages copy their media and
can consume additional disk space; this is not a cloud-offloading feature.

Saving stages and validates the package before replacement. Save-in-place preserves
ancillary files, reuses referenced packaged media and removes media references deleted
by the edit. It compares JSON and file metadata against the opened revision and
rejects detected outside edits. Conflict errors leave the draft intact; use Save As
or reopen. This is optimistic conflict detection, not a lock against arbitrary external
writers. A failed filesystem replacement reports a recovery-copy path when one exists.

Unsaved changes prompt before opening another scene, closing or quitting. Keep Editing
cancels the action. Active import/save operations block it until finished. Reset
Changes retains the current draft, selection, renderer and history if the original
media cannot load. Restore that source and retry, or save the current scene.

## Undo

Native Undo/Redo (⌘Z / ⇧⌘Z) and inspector buttons cover layer commands with named
actions. History is limited to 32 metadata snapshots; it retains no decoded images
or players. Failed renderer preparation cancels Undo before consuming the action.
Text fields have separate native text history. A new scene edit clears redo.
Saving, resetting and opening clear scene history. Asset access lasts while the
current document or an undo target needs it.

## Runtime and structure

`SceneDocument` owns scene/source state, asset access and native undo registration.
`SceneEditorController` owns selection and editing commands. `ScenePreviewHost` owns
the renderer, clock and measurements. The window connects them to AppKit controls;
canvas gestures and the native layer list have separate views.

Opened packages hot-reload when clean and without undo history. Invalid edits keep
the working preview. Use on Desktop hands the saved source to the wallpaper host.
Hidden/minimized windows, sleep and Low Power Mode pause playback; closing releases
it. Opening Studio stops the screensaver preview behind it. Resizing resets canvas
zoom and rebuilds playback. Renderer switching restarts video too.

## Verification

Native UI checks cover scene and text undo, redo, layer selection and dragging,
resizing, rotation, nudging, duplication, zoom/pan, Save As and in-place Command-S.
Automated checks cover 32-step history, failed undo/reset recovery, package round trips,
invalid replacement, outside-edit conflicts, media reuse/removal and symlink rejection.
Decoder, scene and wallpaper lifecycle/GPU smoke suites pass. No new performance or
energy improvement is claimed by the Studio work.

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

### Resource limits

Each display shares a 32-million-pixel still-image decoding allowance across its image
nodes, with at most 16 million pixels per image. More image layers therefore reduce
the maximum decode size per layer. Hidden layers count toward every limit.
This bounds retained image pixels, not total process memory: video decoders, drawables,
temporary uploads, the old renderer during replacement, and additional displays cost extra.
No intermediate effect textures are allocated yet.


Group validation counts all descendants toward the 16-node limit. Four group
containers and two nesting levels are supported. See [v3 group semantics and
texture limits](scenes.md#groups-version-3). Native checks cover creating a group,
changing opacity, switching Standard/Metal, nudging and undo. Automated GPU checks
verify isolated/nested opacity, transform and visibility; allocation tests verify
in-flight exclusivity and bounded resizing; video tests verify live group edits.

### Keyframes

Select a layer and choose **Keyframes…**, select a property and interpolation, then enter comma-separated `time:value` pairs such as `0:-0.3, 3:0.3, 6:-0.3`. Apply replaces that property's existing driver and participates in native Undo. Save persists the track in a V10 package. Use Bind… → Remove Binding to restore the static property.

The sheet loads an existing track and interpolation when its property is selected. Applying edits preserves that track's scale, offset and modifiers; replacing a non-track binding starts a plain track. Remove Track restores the static property and supports Undo.

The timeline beneath the canvas shows time, a scrubber and selected-layer key markers. Scrubbing pauses and redraws Metal motion immediately. Its range uses authored duration, otherwise the last scene key (eight seconds without tracks). Loop Range starts a preview loop over that range; Time… adjusts or disables it. Opening a different scene applies authored playback; same-scene hot reload preserves transport unless authored playback changed. The status readout shares the existing one-second performance tick and stops updating while the host is suspended. Choose a property in the timeline track picker to see only its keys. Drag a key to change time and value; release commits one Undo action. Keys stop before their neighbours and retain interpolation/modifiers. Click a key then use Left/Right to nudge by 0.1 seconds (Shift: one second); Escape cancels an unfinished drag. For extending the visible range, edit the endpoint time in Keyframes…. A drag previews the curve and updates scene motion on release. Video following is opt-in and approximate; see V13 below.


### Authored playback (V11)

**Playback…** saves duration (0.01–86400 seconds), mode (Once, Loop, Ping-pong), and speed (0.1–4×) as document data, with Undo/Redo. Save/Save As writes `timeline: {"duration": 6, "mode": "loop", "rate": 1}` into scene.json and selects manifest version 11. Remove restores unbounded scene time. Earlier packages remain unchanged.

Studio and desktop apply authored playback on selection. A changed authored timeline restarts at zero; unchanged hot reload preserves the clock. Pause/resume preserves ping-pong direction. Time… and Loop Range remain temporary preview overrides; editing layers preserves those overrides, while changing authored playback or opening another scene replaces them. Scrubbing seeks the authored clock without removing its mode. The visible timeline uses authored duration when present. Videos remain independent unless following is enabled. Keyframed Aurora now demonstrates a saved six-second loop.


### Curve editing

The selected track has a compact curve display for hold, linear, and ease-in-out interpolation. Drag a key horizontally for time and vertically for its authored source value; one release makes one Undo step. The range fits the keys and stays fixed during a drag. The selected key shows exact time/value text. Shift snaps time to whole seconds, double-click empty curve space inserts a key sampled from the existing track, and Delete removes a selected key (at least one remains). Left/Right still nudge time. Edits preserve modifiers and keep the renderer alive. Curve values are source values before binding modifiers and final property clamping. Clipboard operations and timeline zoom are still pending. Smoothing and experimental video transport are described below.


### Signal smoothing (V12)

Bind… includes Smoothing (0–5 seconds). Zero disables it. Positive values apply exponential smoothing to signal/keyframe output after scale, offset and modifiers, before the target's property clamp. Parameter-only drivers reject smoothing in this first implementation. The time constant is measured in real seconds (about 63% of a step after one time constant), independent of display refresh or scene speed. Adjustable Aurora demonstrates 0.18-second pointer smoothing.

Only the duration is saved. Each Metal renderer owns bounded filter memory for its binding targets, with no extra timer. Loading, live scene edits, pause/resume and explicit transport changes reset filter history; normal authored looping retains it. Seeking therefore gives a deterministic fresh value instead of dragging old motion into the new position. This is exponential smoothing, not a spring simulation.

Video transport uses separately managed items because AVPlayerLooper replicas must not have their playhead modified ([Apple documentation](https://developer.apple.com/documentation/avfoundation/avplayerlooper/loopingplayeritems)). The opt-in implementation is described below.


### Experimental video transport (V13)

Playback… → **Videos follow scene time** opts all video nodes into the scene playhead and saves that choice. This selects separately managed video items rather than AVPlayerLooper replicas. Once and Loop support preview seeking, authored speed, pause/resume, and periodic drift correction; Ping-pong is rejected with video following enabled. Shorter videos repeat within the scene duration.

Only one seek per video can be in flight, newer playhead positions supersede older ones, and routine corrections are limited to ten per second with a 120 ms running drift tolerance. This is approximate synchronization, not frame locking or seamless-loop parity with the independent video path. Keep following disabled for ordinary video wallpapers when synchronization is unnecessary. Tests verify changing decoded pixels across paused seeks, latest-seek convergence, source-duration wrapping, live edits, and teardown.
