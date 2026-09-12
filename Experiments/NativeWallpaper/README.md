# Native wallpaper catalog probe

Separate, non-shipping ExtensionKit experiment. Apple’s Wallpaper settings can
load its **Idlesse Lab → Synthetic Orbit** catalog. Rendering is not implemented:
do not select the tile. The probe reads no Library or personal media assets.

## Build and test

From the repository root:

```sh
glaeda-apple --profile native-probe-xcode plan
glaeda-apple --profile native-probe-xcode warm
```

The managed products directory contains `Idlesse Native Probe.app` and
`runtime-inspection.json`. The companion generates a synthetic 640×360 poster and
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
Acquire deliberately replies with a not-implemented error.

## Next gate

Implement synthetic remote surface acquire/update/invalidate and snapshots. Test
one display with a restorable prior assignment before connecting the real Library.
Then qualify lock, sleep, hotplug, and assignment synchronization. Keep this
experiment independent of the shipping wallpaper renderer.

The private framework and protocol require qualification per OS version. The
catalog model reference is vendored under MIT in `Vendor/`, with its pinned
revision and license. Discovery was informed by
https://github.com/kageroumado/phosphene.
