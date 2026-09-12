# Native wallpaper discovery probe

This is a separate, non-shipping ExtensionFoundation app/extension experiment.
It cannot choose or render a wallpaper. It deliberately declines XPC connections
and never exports an interface. It reads no Library or personal media assets.

## Build

From the repository root:

```sh
glaeda-apple --profile native-probe plan
glaeda-apple --profile native-probe warm
```

The managed products directory contains `Idlesse Native Probe.app` and
`runtime-inspection.json`. The build compiles both executables with the local SDK,
ad-hoc signs the sandboxed extension and containing app, verifies their signatures,
and runs the framework/class probe. No paid signing identity is selected.

Register the exact generated app path for a short, attended discovery test:

```sh
Experiments/NativeWallpaper/registration.sh register "/absolute/path/Idlesse Native Probe.app"
```

Open System Settings → Wallpaper and inspect the `dev.idlesse.nativeprobe`
subsystem in unified logging. This probe serves no settings model, so it should
not be expected to appear as a selectable tile. WallpaperAgent can log failed
settings-model requests; unregister after gathering the launch evidence:

```sh
Experiments/NativeWallpaper/registration.sh unregister "/absolute/path/Idlesse Native Probe.app"
```

Registration script output must be checked: command exit success alone did not
prove discovery when the extension was initially placed in the wrong directory.

## Verified on 2026-09-12

macOS 26.6.2 (25G83), SDK 26.5, arm64:

- The private WallpaperExtensionKit framework loads and the five queried XPC
  classes exist.
- Both ad-hoc signatures pass strict verification.
- `Contents/PlugIns` did **not** register this ExtensionKit extension.
- `Contents/Extensions` did register it under `com.apple.wallpaper`.
- WallpaperAgent launched the sandboxed extension when Wallpaper settings opened.
- The extension logged initialization. Loading the private framework inside the
  extension also reached configuration requests.
- No settings model, render surface, snapshot, or wallpaper assignment was served.
  No conclusion about rendering, lock-screen playback or long-term stability follows.
- No Apple developer certificate was needed for **registration and host launch**.
  Distribution/notarization and full provider operation remain separate questions.

The main app and current wallpaper were not replaced. The test registration was
removed after observation. Build caches and local receipts remain reusable.

## Next gate

Implement a minimal fixed settings collection plus one synthetic scene, with
explicit host identity validation, a narrow XPC decoding class allowlist, and
unsupported-method replies. Verify a selectable tile before implementing remote
surface acquire/update/invalidate and snapshots. Then test one display and restore
its previous provider through normal system controls. Only after that connect
Idlesse's real Library and test lock, sleep, hotplug and assignment synchronization.

The discovery/configuration approach was informed by Phosphene's source:
https://github.com/kageroumado/phosphene
No Phosphene implementation files are vendored. The framework and protocol are
private APIs and need OS-version qualification independently of the public app.
