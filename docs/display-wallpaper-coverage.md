# Per-display wallpapers and coverage-rest qualification

This pass reconciles issue #28 Track A and Track D into one implementation. Track A behavior comes from PR #45; coverage hardening folds in the useful parts of PR #48 while keeping coverage rest opt-in.

## Per-display Library assignment

Open the Idlesse wallpaper status menu, choose **Displays → Assign Library Wallpapers…**, then use the native Display Wallpapers window.

- **Same wallpaper on all displays** remains the default and simplest path. Compatible Metal video scenes use one `SharedVideoHub`, so connected displays consume one playback engine.
- With shared mode disabled, each connected display can choose a built-in or saved Library wallpaper. Displays without an override follow the default wallpaper.
- Assignments use the display UUID returned by Core Graphics. Existing bookmarks stored under the older transient `NSScreenNumber` key migrate when that display is seen again. Disconnecting a display leaves its bookmark intact for reconnect.
- Per-display Library URLs keep a security-scoped lease for the lifetime of the surface using them, including scene transitions.
- A **Desktop Span** scene always renders as one continuous canvas across every connected display. Selecting a span scene from an individual display row promotes it to the all-display canvas while retaining saved individual assignments. Selecting an ordinary scene later restores the chosen shared/individual mode.
- System wallpaper stills follow the per-display runtime assignment, so Mission Control and desktop transitions match the active scene on each display.

## Coverage rest policy

Coverage rest remains **off by default**. It stays an opt-in energy experiment until interactive macOS qualification shows clean behavior and a repeatable reduction in rendering/GPU work.

The monitor samples every three seconds. A display enters rest after two consecutive samples at or above **95%** coverage and resumes after two consecutive samples at or below **85%**. Samples in the middle band hold the current state and cancel incomplete transitions.

Each display owns an independent tracker keyed by its persistent display identifier. One covered display can rest while another keeps rendering. `SharedVideoHub` keeps playback active while any connected display remains visible and pauses only when every display rests, or when the normal global pause path applies.

A tracker becomes stale after an **8 second** sampling gap. A rested display wakes immediately on a stale reset and must reconfirm high coverage before resting again. Scene replacement, surface release and rebuild paths also clear coverage trackers, so old decisions do not survive display recreation.

Coverage measurement excludes Idlesse windows, the Idlesse process, known system-chrome owners (`Dock`, `Notification Center`, `Screenshot`, `Control Center`, `SystemUIServer`, `Window Server`), and any whole-window alpha below **0.98**. Ambiguous translucent overlays therefore keep the wallpaper active.

Every enabled sampling pass writes an `Idlesse-coverage` line to `/tmp/idlesse-state.log` with the stable display identifier, frame, measured fraction, current rest state, pending candidate/sample count, considered/ignored window counts and thresholds. Stale resets add an `Idlesse-coverage-reset` line with the sampling gap and previous rest state.

## Focused checks

`Tests/WallpaperPolicyTests.swift` exercises:

- 95%/85% hysteresis and two-sample entry/exit stability;
- candidate cancellation when samples return to the middle band;
- independent per-display rest state;
- shared playback continuing while any display remains visible;
- stale sampling reset and coverage reconfirmation;
- whole-window translucency filtering and sampled union coverage;
- stable display-assignment keys across transient display-ID changes;
- migration and clearing of legacy numeric display keys.

Run it with the normal suite:

```sh
bash test.sh
```

## Qualification metrics

`--qualify-desktop` now records, per display and sample:

- persistent display identifier and transient screen number;
- display frame and coverage-rest state;
- submitted and presented frame counts;
- accumulated GPU seconds and GPU frame count where supported;
- renderer loop/menu-strip counters.

The report also records whether coverage pause was enabled. Compare deltas across sustained visible and covered intervals; a useful rest interval should drive the affected display's submitted/presented/GPU deltas close to zero while an uncovered sibling display continues normally.

## Interactive macOS qualification matrix

| Case | Expected behavior |
| --- | --- |
| Opaque fullscreen app on display A, bare desktop on B | A rests after two high samples; B continues rendering and shared video playback continues. |
| Opaque fullscreen apps on both displays | Both rest independently; shared video playback rests once both are stable. |
| Large window covering roughly 86–94% | Current state holds through the hysteresis band. |
| Window moves from fullscreen to clearly exposed desktop | Rested display resumes after two samples at or below 85%. |
| Translucent utility/overlay window | Wallpaper continues; ignored translucent coverage is logged. |
| Menu bar, Dock, Control Center, Notification Center, screenshot UI | System chrome alone never causes a full-display rest. |
| Stage Manager rearrangement | No rapid rest/resume chatter; transitions require two stable samples. |
| Mission Control / Spaces transition | No one-sample pause; a long sampling interruption wakes a rested display and reconfirms coverage. |
| Display disconnect and reconnect | Saved per-display Library assignment returns on the same physical display and coverage state reconfirms. |
| Desktop Span scene across displays | One continuous canvas remains visible across display boundaries; individual assignments remain saved for the next ordinary scene. |

A default-on decision requires correctness evidence from this matrix and measured rendering savings. False rests on visible transparent content, or trivial renderer/GPU savings, are reasons to remove coverage rest instead of adding more compositor-specific exceptions.
