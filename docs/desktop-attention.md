# Desktop-attention creative signal

Issue #42 adds one narrow host-fed creative input: `desktop.attention`.

## Meaning and privacy

`desktop.attention` is normalized to `0...1` per display:

- `1` means the desktop is fully exposed;
- `0` means other windows cover the display;
- intermediate values are the visible fraction, computed as `1 - rawCoverageFraction`.

The scene receives only that number. App names, bundle identifiers, window titles, process identities and individual window geometry stay inside the existing coverage observer and never enter `SceneSignals` or authored scene data.

The artistic input is deliberately independent from coverage-rest. Coverage-rest keeps its 95%/85% hysteresis and stable-sample policy; `desktop.attention` follows the raw normalized observation. Authored binding `smoothing` supplies the visual easing.

Packages using the signal declare the revision-21 `desktop-attention` capability. A binding is otherwise ordinary scene motion:

```json
{
  "target": {"nodeID": "…", "property": "opacity"},
  "signal": "desktop.attention",
  "scale": 0.6,
  "offset": 0.2,
  "smoothing": 1.5
}
```

## Host behavior

The wallpaper controller reuses the existing three-second coverage timer and `CoverageMonitor.measurement` call. An attention scene causes that existing loop to remain useful even when coverage-rest itself is disabled; there is no second window-list scanner or attention-specific timer.

Each `WallpaperSurface` receives its own display sample. Independent assignments therefore get independent attention values, while Desktop Span still receives one value per physical display surface.

Global pause states freeze the creative value: user pause, bedtime pause and Low Power Mode stop attention-only sampling. Display sleep and inactive-session handling already releases surfaces. A rebuilt/resumed surface starts at `1.0`, then the controller immediately performs a fresh coverage observation before continuing. Coverage-rest can still consume its raw measurements independently when its opt-in switch is enabled.

## Demonstration: Quiet Wake

`Examples/DesktopAttention.idlesse` is a restrained dusk/firefly scene. As coverage rises, the fireflies slow and dim while the vignette deepens. As the desktop returns, authored smoothing lets the field wake over roughly one to two seconds instead of snapping with the three-second host sampling cadence.

## Qualification and overhead

Two focused measurements accompany the feature:

1. `Tests/WallpaperPolicyTests.swift` times repeated real `CoverageMonitor.measurement` calls when a logged-in display exists. This is the scan cost already paid by coverage-rest; attention reuses it.
2. `Tests/DesktopAttentionTests.swift` compares ordinary scene evaluation with evaluation of one `desktop.attention` binding and prints the incremental microseconds per evaluation.

`--qualify-desktop` also records cumulative coverage-observation count/time and attention-dispatch count/time, plus each display's latest `desktopAttention`, submitted/presented frame totals and GPU totals. That makes the full host cost visible during a physical qualification run.

The measurements are reported rather than used as brittle CI thresholds because hosted runner load varies.

## Scope boundary

This experiment adds only `desktop.attention`. System appearance, Low Power state, primary-display role and geometry constants remain candidates for later work if creators can demonstrate clear artistic use. Keeping the first surface tiny makes the feature easy to remove if real scenes feel gimmicky or the sampling cost outweighs the payoff.
