# Creative runtime, scene format v2

Version 1 packages keep their existing `layers` format. Version 2 uses `nodes`:

```json
{"version":2,"title":"Aurora","capabilities":[]}
```

```json
{"nodes":[
  {"type":"gradient"},
  {"type":"image","asset":"assets/foreground.png","opacity":0.8,
   "transform":{"x":0.1,"y":0,"scale":0.8,"rotation":5}}
]}
```

Nodes are ordered back to front; up to two are accepted. Typed content is image,
video, or the built-in Metal gradient. Translation uses fractions of the display
width/height (positive y is up), rotation uses degrees about the node center,
and scale is uniform. x/y range from -2 to 2; scale 0.05–4; rotation -360–360.
Default transform is identity. Normal alpha blending is the only blend mode.
The root clips transformed content to the display. Resize currently reconstructs
surfaces using the new screen geometry, rather than mutating renderers in place.

The built-in gradient targets 30 fps and permits at most two GPU submissions in
flight; it pauses its MTKView draw loop and releases drawables on disposal.
It is not an arbitrary shader loader or a multipass effect on other nodes.
See Apple's MTKView drawing modes:
https://developer.apple.com/documentation/MetalKit/MTKView

One SceneClock provides monotonic elapsed time across an active scene's surfaces.
It freezes for manual pause, sleep/session suspension, and Low Power Mode.
A successful live edit preserves the clock and manual pause; a new selection
starts a new timeline. Native video players are not frame-locked to this clock.

The renderer interface exposes lifecycle methods and diagnostics, not AVPlayer.
Diagnostics report state, active renderer resources, loops and submitted Metal
frames. Resource counts are not RAM measurements; frame counts are submissions,
not proof of frames presented on a display. Memory and dropped-frame profiling
remain future work.

Open packages are watched using filesystem events, with a 350 ms debounce.
Metadata, referenced assets and their parent directories are observed so atomic
saves are detected. Valid edits replace the scene; invalid edits retain the last
working scene and show a concise error in the menu. Stop removes observation.
No recursive polling, cloud fetching, script execution, editor UI, or arbitrary
network capabilities are added. New asset directories begin being watched once
a valid scene references them.

Try `Examples/Gradient.idlesse`: it needs no media download. Open it through
Wallpaper… in the newly built app, then edit scene.json and save.
