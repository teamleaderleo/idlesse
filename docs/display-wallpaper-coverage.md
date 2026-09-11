# Per-display wallpapers and coverage-rest qualification

This focused pass implements issue #28 Track A and Track D together because both paths own display identity and per-display runtime state.

## Per-display Library assignment

Open the Idlesse wallpaper status menu, choose **Displays → Assign Library Wallpapers…**, then use the native Display Wallpapers window.

- **Same wallpaper on all displays** remains the default and the simplest path. Compatible Metal video scenes use one `SharedVideoHub`, so connected displays consume one playback engine.
- With shared mode disabled, each connected display can choose a built-in or saved Library wallpaper. Displays without an override follow the default wallpaper.
- Assignments use the display UUID returned by Core Graphics. Existing bookmarks stored under the older transient `NSScreenNumber` key migrate when that display is seen again. Disconnecting a display leaves its bookmark intact for reconnect.
- Per-display Library URLs keep a security-scoped lease for the lifetime of the surface using them, including scene transitions.
- A **Desktop Span** scene always renders as one continuous canvas across every connected display. Selecting a span scene from an individual display row promotes it to the all-display canvas while retaining saved individual assignments. Selecting an ordinary scene later restores the chosen shared/individual mode.
- System wallpaper stills follow the per-display runtime assignment, so Mission Control and desktop transitions match the active scene on each display.

## Coverage rest policy

Coverage rest remains **off by default**. It is an opt-in energy experiment until interactive macOS qualification shows a clean false-positive record and a repeatable reduction in rendering/GPU work.

The monitor samples every three seconds. A display enters rest after two consecutive samples at or above **95%** coverage and resumes after two consecutive samples at or below **82%**. The gap is intentional hysteresis: window edges and animated transitions can move through the middle band without repeatedly pausing and resuming a renderer.

Each display owns an independent tracker. One covered display can rest while another keeps rendering. `SharedVideoHub` keeps playback active while any connected display remains visible and pauses only when every display rests, or when the normal global pause path applies.

Coverage measurement excludes Idlesse windows, the Idlesse process, known system-chrome owners (`Dock`, `Notification Center`, `Screenshot`, `Control Center`, `SystemUIServer`, `Window Server`), and strongly translucent windows. Ambiguous translucent overlays therefore keep the wallpaper active.

Every enabled sampling pass writes an `Idlesse-coverage` line to `/tmp/idlesse-state.log` with:

- stable display identifier and display frame;
- measured coverage fraction and current rest state;
- pending rest/resume candidate plus consecutive sample count;
- windows considered, system-chrome windows ignored, and translucent windows ignored;
- active rest/resume thresholds.

## Focused checks

`Tests/WallpaperPolicyTests.swift` exercises the deterministic policy without AppKit:

- two-sample entry and exit stability;
- hysteresis deadband behavior;
- one display resting while another remains active;
- shared playback continuing until every display rests;
- stable display-assignment keys across a simulated transient display-ID change;
- migration and clearing of legacy numeric display keys.

Run it with the normal suite:

```sh
bash test.sh
```

The existing wallpaper smoke path continues to cover sampled geometry via `CoverageMonitor.coveredFraction` and the desktop-surface renderer checks.

## Interactive macOS qualification matrix

Before considering a default-on change, exercise coverage rest on a physical multi-display Mac with `/tmp/idlesse-state.log` open and record presented-frame/GPU totals before and after each case.

| Case | Expected behavior |
| --- | --- |
| Opaque fullscreen app on display A, bare desktop on B | A rests after two high samples; B continues rendering and shared video playback continues. |
| Opaque fullscreen apps on both displays | Both rest independently; shared video playback rests once both are stable. |
| Large window covering roughly 80–94% | Current state holds through the hysteresis band. |
| Window moves from fullscreen to clearly exposed desktop | Rested display resumes after two samples at or below 82%. |
| Translucent utility/overlay window | Wallpaper continues. Log reports ignored translucent coverage where applicable. |
| Menu bar, Dock, Control Center, Notification Center, screenshot UI | System chrome alone never causes a full-display rest. |
| Stage Manager rearrangement | No rapid rest/resume chatter; transitions require two stable samples. |
| Mission Control / Spaces transition | No one-sample pause; state changes only after consecutive stable measurements. |
| Display disconnect and reconnect | Saved per-display Library assignment returns on the same physical display. |
| Desktop Span scene across displays | One continuous canvas remains visible across display boundaries; individual assignments remain saved for the next ordinary scene. |

A default-on decision needs both correctness evidence from this matrix and measured rendering savings during sustained coverage. This pass leaves the default disabled because the current execution environment cannot exercise macOS window-server interactions or physical multi-display GPU behavior.
