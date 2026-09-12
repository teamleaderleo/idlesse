# Track E — WallpaperController responsibility map

Issue #28 Track E should begin only after the combined display-assignment/coverage branch lands. This note maps the current ownership so the later decomposition can preserve behavior instead of redesigning it mid-merge.

## Current ownership

`WallpaperController` currently acts as the wallpaper-runtime facade and owns several distinct areas:

- **Selection and source lifecycle** — selected URL, async scene resolution, generation/cancellation, failed-replacement retention, resume bookmarks, file watching and live scene reload.
- **Display assignment** — shared-vs-independent mode, persistent Core Graphics display identity, per-display bookmark resolution, security-scoped access and assignment refresh.
- **Surface lifecycle** — screen enumeration, `WallpaperSurface` creation, rebuilds after screen changes, teardown, retiring surfaces and renderer configuration.
- **Desktop Span** — all-display canvas geometry and the rule that span scenes temporarily override ordinary per-display assignments without erasing them.
- **Shared media** — active/retiring `SharedVideoHub` ownership and the rule that compatible same-scene displays share playback.
- **Playback policy** — user pause plus sleep/session/bedtime/low-power state, per-display coverage rest, renderer pause calls and shared-hub pause decisions.
- **Transitions** — current/retiring surface sets, transition timing and final cleanup.
- **System desktop integration** — matching system wallpaper stills, original-backdrop bookkeeping, clean-desktop behavior and Finder/right-click integration.
- **Lifecycle observation** — screen changes, workspace/session events, sleep/wake and related rebuild/resume behavior.
- **Menu/UI integration** — status-menu state, commands, validation and entry points into display assignment and desktop controls.

## Candidate seams

The safest later extraction order is:

1. **DisplayAssignmentCoordinator** — `DisplayAssignmentStore`, stable display IDs, effective per-display source resolution, security-scope lease decisions and matching backdrop selection. Preserve Desktop Span promotion/restoration exactly.
2. **PlaybackPolicy** — explicit global pause reasons (`user`, bedtime, low power, system sleep, inactive session) plus per-display coverage reasons. Its output should be the desired pause state for each surface and for `SharedVideoHub`; it should own no AppKit windows.
3. **SurfaceCoordinator** — connected-screen reconciliation, surface creation/release, hotplug rebuilds and renderer wiring. It should consume resolved assignments and playback decisions.
4. **TransitionCoordinator** — retiring surfaces/hubs, transition duration/progress and cleanup. Keep selection/loading outside it.
5. **DesktopIntegration** — system-backdrop stills, clean desktop and Finder/native desktop interaction.

`WallpaperController` can remain the public facade that coordinates selection, commands and the extracted collaborators.

## Invariants to preserve during Track E

- Stable display UUID assignments survive reconnect and legacy-key migration.
- Same-wallpaper mode keeps compatible shared-video decoding/playback semantics.
- Independent assignments keep independent runtime surfaces and matching per-display system backdrops.
- Desktop Span stays one continuous canvas and preserves ordinary assignments for later restoration.
- Failed scene replacement leaves the working scene alive.
- Security-scoped access lives at least as long as the surface that consumes it.
- Coverage rest remains per-display and opt-in; global pause reasons still dominate.
- A shared video hub pauses for coverage only when every consuming display rests.
- Screen/session/sleep transitions cannot resurrect stale coverage state.
- Existing menu commands and externally visible behavior remain unchanged during decomposition.

No Track E code movement belongs in the display/coverage reconciliation PR.
