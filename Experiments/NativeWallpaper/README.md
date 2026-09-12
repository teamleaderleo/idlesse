# Native wallpaper catalog probe

Separate, non-shipping ExtensionKit experiment. Apple’s Wallpaper settings can
load its **Idlesse Lab → Synthetic Orbit** catalog. A synthetic remote-layer
renderer and snapshots are implemented and locally tested. Actual host rendering
is not yet visually verified; select it only during an attended, restorable test.
The probe reads no Library or personal media assets.

## Build and test

From the repository root:

```sh
glaeda-apple --profile native-probe-xcode plan
glaeda-apple --profile native-probe-xcode warm
```

The managed products directory contains `Idlesse Native Probe.app` and
`runtime-inspection.json`, `catalog-check.txt`, and `surface-check.txt`. The companion generates a synthetic 640×360 poster and
checks secure catalog serialization against the installed framework. Xcode builds
the extension using its `com.apple.product-type.extensionkit-extension` product
and `_NSExtensionMain` entry point. Both bundles are ad-hoc signed and verified;
no paid signing identity is selected.

The older `native-probe` profile remains a direct-compiler comparison build. It
passed serialization and launched, but did not receive host connections. Use the
Xcode profile for live catalog tests. The entry point differs; generated metadata
and other Xcode settings also differ, so the entry point alone has not been
isolated as the cause.

Register one exact generated app path for an attended test:

```sh
Experiments/NativeWallpaper/registration.sh register "/absolute/path/Idlesse Native Probe.app"
```

Open System Settings → Wallpaper. Inspect the `dev.idlesse.nativeprobe` unified-log
subsystem, then unregister after gathering evidence:

```sh
Experiments/NativeWallpaper/registration.sh unregister "/absolute/path/Idlesse Native Probe.app"
```

Inspect registration output, not just exit status. `Contents/Extensions` is the
required placement; `Contents/PlugIns` did not register. Avoid registering multiple
build copies because cached copies can make launch diagnostics ambiguous.

## Verified on 2026-09-12

macOS 26.6.2 (25G83), SDK 26.5, arm64:

- Framework loading and secure catalog round-trip pass. Apple's decoder requires
  `sortID` despite the reference shim declaring it optional.
- Strict ad-hoc signature verification passes.
- The Xcode-built extension receives WallpaperAgent's connection and validates
  its audit token against Apple's signature and WallpaperAgent identifier.
- The live handler serves the synthetic catalog. System Settings visibly displays
  **Idlesse Lab**, the generated poster, and **Synthetic Orbit**.
- Logs at 16:59:43 report initialization, connection entry, verified peer, and
  serving the settings tile, in that order.
- No tile was selected. No render surface, snapshot, or wallpaper assignment was
  served. This does not establish rendering, lock-screen playback, distribution,
  notarization, or long-term compatibility.

The caller check fails closed. The XPC interface permits only the catalog,
download-status, and acquire methods with narrow decoding class allowlists.
Lifecycle calls now create, resize/update, snapshot, and invalidate surfaces.
The surface store is serial and shared across short-lived connections. Repeated
acquire of the same UUID reuses its context. Four surfaces maximum; destination
geometry is bounded to 8192 pixels per edge and 34 million pixels, and snapshots
are capped at 1920 on their longest edge. A Core Animation orbit avoids a CPU
frame timer; inactive host activity pauses the scene. No media decoder is used.

The private context/snapshot wrappers are isolated in `Surface.swift`. They require
macOS 26, named ivars, and the observed exact instance sizes; changed layouts fail
closed. This is experimental ABI coupling, not a supported public framework API.

## Surface follow-up on 2026-09-12

The managed build runs a local surface check covering:

- Secure remote-context archive/decode round-trip and repeated-acquire reuse.
- Explicit invalidation and rejection of snapshots for released IDs.
- Four-surface capacity, invalid geometry rejection, snapshot dimensions/size,
  and an opaque BGRA background pixel.
- Repeated snapshot construction/release (100 iterations) and pause/resume time.

These checks create unhosted contexts, not desktop windows or wallpaper assignments.
The updated catalog was visible in Settings, but the Mac locked before selection.
No native surface acquire/snapshot has been claimed as visually verified. Test
registration was removed without selecting a different wallpaper.

## Next gate

Unlock the test desktop, register the staged probe, and select Synthetic Orbit
on one display. Verify motion, snapshots, updates, and invalidate logs, then restore
the recorded prior assignment through normal settings before unregistering. Do
this before connecting the real Library.
Then qualify lock, sleep, hotplug, and assignment synchronization. Keep this
experiment independent of the shipping wallpaper renderer.

The private framework and protocol require qualification per OS version. The
catalog model reference is vendored under MIT in `Vendor/`, with its pinned
revision and license. Discovery was informed by
https://github.com/kageroumado/phosphene.

## Attended test workflow

Use the M27P6 27-inch monitor as the primary workspace and existing Idlesse media
for product testing. Do not add new preview windows or move windows to other
displays to work around UI automation failures.

The follow-up native selection attempt hit the UI control service's
`cannotClickOffscreenElement` / `windowNotFoundAtPosition` errors despite a visible
tile. No acquire was observed. Do not move Settings between monitors, the iPad,
or automation displays to work around this: leave the user's workspace alone and
stop the UI test if the tool cannot target the visible tile.

Build-time CLI checks may cause Launch Services to discover the generated app.
The Xcode build now unregisters its exact products path afterward, keeping live
registration an explicit staged-path action. Unregister is idempotent and still
removes the containing app when the extension was already removed.
