# Automation surface

Idlesse automation uses one typed `AutomationCommand` contract for URLs, the command line, App Intents / Shortcuts, hotkeys, and internal dispatch. External transports only parse and submit commands; wallpaper, Library, Ambient Set, pause/resume, and desktop visibility behavior remain owned by their normal controllers.

## URL scheme

The existing `idlesse` scheme keeps its UI routes. Automation uses the explicit `automation` host:

- `idlesse://automation/apply-scene?id=builtin.Undertow`
- `idlesse://automation/apply-collection?id=<collection-id>`
- `idlesse://automation/apply-ambient-set?id=<ambient-set-id>`
- `idlesse://automation/set-variant?name=Midnight&scene=<optional-library-id>`
- `idlesse://automation/next`
- `idlesse://automation/previous`
- `idlesse://automation/pause`
- `idlesse://automation/resume`
- `idlesse://automation/toggle-pause`
- `idlesse://automation/pause-for?seconds=3600`
- `idlesse://automation/clean-desktop`
- `idlesse://automation/state`
- `idlesse://automation/login-item?enabled=on`
- `idlesse://automation/screen-share-state`

Identifiers are percent-decoded by `URLComponents`. Commands are bounded: identifiers are at most 1024 UTF-8 bytes and timed pauses are 1–86400 seconds.

## Command line

The application executable exposes the same grammar through `--ctl` once the runtime transport is connected:

```
Idlesse --ctl apply-scene builtin.Undertow
Idlesse --ctl apply-collection focus
Idlesse --ctl apply-ambient-set presentation
Idlesse --ctl set-variant Midnight --scene builtin.Undertow
Idlesse --ctl next
Idlesse --ctl previous
Idlesse --ctl pause
Idlesse --ctl resume
Idlesse --ctl toggle-pause
Idlesse --ctl pause-for 3600
Idlesse --ctl clean-desktop
Idlesse --ctl state
Idlesse --ctl login-item on
Idlesse --ctl screen-share-state
```

The command model is transport-neutral, Codable, and covered headlessly in `Tests/AutomationCommandTests.swift`.

## State semantics

Runtime integration should preserve the existing ownership rules:

- scene and collection IDs resolve through Library storage and its security-scoped access semantics;
- explicit scene/collection/Ambient Set actions become explainable manual choices instead of bypassing Ambient Set hold rules;
- pause/resume uses the wallpaper controller's user-pause state, including timed-pause restoration;
- clean desktop uses the existing Files / Widgets visibility controls;
- named variants use the revision-21 `SceneDescriptor.applyingVariant(id:)` layer and should remain part of current wallpaper state rather than a second renderer path.

## Screen sharing

ScreenCaptureKit exposes public capture metadata including `SCWindow.isActive`, which reports whether a shareable window is currently streaming. Enumerating shareable content can require Screen Recording authorization, and the public API does not provide a reliable global event for every form of display sharing. Whole-display sharing and capture paths outside ScreenCaptureKit also cannot be inferred safely from `SCWindow.isActive` alone.

For that reason Idlesse treats screen-share detection as an explicit capability probe / experimental opt-in. The default automation policy does not request Screen Recording permission or run a background polling loop merely to guess whether sharing is active. A future opt-in can use the same command layer once its limitations are acceptable and visible to the user.
