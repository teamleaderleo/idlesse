# Native wallpaper discovery probe

This is a separate, non-shipping ExtensionFoundation app/extension experiment.
It cannot render a wallpaper. It implements a fixed synthetic catalog and a narrow
XPC interface, but the live host handshake remains unresolved. It reads no Library
or personal media assets. Do not select its tile until rendering is implemented.

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
subsystem in unified logging. A local catalog serialization check passes, but the host has not yet reached
the implemented settings handler. WallpaperAgent can log failed
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
The catalog reference is vendored under MIT in `Vendor/`. The framework and protocol are
private APIs and need OS-version qualification independently of the public app.

## Catalog follow-up

The current probe targets macOS 26 and adds a fixed **Idlesse Lab / Synthetic
Orbit** desktop catalog. It bundles a generated 640×360 PNG (no personal assets).
The build now runs `--catalog-check`, which securely archives the local model and
successfully decodes it into Apple's `WallpaperSettingsViewModelsXPC` class.
Apple's decoder requires `sortID`, despite the reference shim marking it optional;
that omission was caught and fixed before registering the extension.

The handler validates the peer's audit token against Apple's signature and the
WallpaperAgent identifier, then offers only the narrow catalog/download/acquire
interface. Unknown identity is rejected. Acquire returns a not-implemented error.
These are implemented paths, **not yet verified as reached by WallpaperAgent**.

Live result remains incomplete: System Settings launches the provider, but it
exits/disconnects before the connection-entry diagnostic. No catalog-served log
and no tile were observed. Tested a fresh provider identifier
`dev.idlesse.nativeprobe.catalog`, a stable staged bundle path, reopening Settings,
and one WallpaperAgent restart. Older cached builds were also observed launching,
so registration of multiple generated paths is an additional source of ambiguity.
The handshake's root cause is still unresolved; do not interpret the local model
round-trip as proof of native provider functionality or certificate requirements.

All probe build copies were unregistered afterward. The normal app was not rebuilt
or replaced, no tile was selected, and the user's wallpaper was not changed.

The next investigation should reproduce the connection issue in a minimal native
Xcode ExtensionKit target, compare its generated bundle and launch metadata with
this script-built target, and retain the same catalog check. Do not weaken caller
validation to work around a connection that never reaches that validation.

The original discovery notes above describe the prior revision. `Vendor/` contains
the MIT Codable model reference, pinned with its license and source revision.
