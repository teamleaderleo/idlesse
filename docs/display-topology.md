# Displays topology and assignment

Issue #31 is layered directly on the assignment runtime from #52. `DisplayAssignmentController` owns presentation; `WallpaperController` remains the authority for applying scenes, security-scoped bookmarks, SharedVideoHub reuse, Desktop Span promotion, and system-backdrop stills.

## Display identity

`CGDirectDisplayID` is a live-session handle only. `DisplayIdentity` records the ColorSync display UUID plus vendor/model/serial, built-in state, physical millimetres, and the localized display name. The hardware fingerprint is the canonical persistence key so an assignment survives a reissued ColorSync UUID; ColorSync UUID remains the exact-match/session alias used by #52. Truly indistinguishable siblings receive a deterministic relative-position suffix instead of persisting their current numeric CG handle.

`DisplayAssignmentStore.reconcile(identityKey:persistentID:legacyDisplayID:)` migrates the existing #52 UUID/direct-CG assignment keys onto the durable identity key while retaining compatibility aliases. A reconnected display can therefore seed a newly issued session UUID from the durable assignment. Clearing an assignment clears the canonical durable copy as well.

## Topology

`DisplayTopology` captures real AppKit frames, backing scale, pixel resolution, main-display status, and Core Graphics mirror-master relationships. `normalizedFrames(in:)` scales the union of those real frames into the visual canvas while preserving negative origins, vertical offsets, gaps, portrait/landscape proportions, and mixed resolutions.

Mirrored displays retain their own snapshot for diagnostics but resolve wallpaper assignment through the mirror master. Desktop Span remains a global scene mode and disables Same on All / Per Display switching while active.

## Known arrangements

`KnownDisplayArrangementsStore` records topology signatures with hard-bounded JSON state in UserDefaults: at most 16 recent arrangements with at most 16 member identities each. A lone built-in panel begins as **MacBook Only**; multi-display layouts begin as **Desk Setup**. Reconnecting a known docked/undocked combination reuses the matching profile. Profiles describe remembered arrangements; macOS continues to own physical monitor placement.

## Library assignment flow

Displays contains no second Library catalog. Selecting **Choose in Library…** opens the real Library. In Per Display mode, the next Library **Set Wallpaper** is captured as the selected monitor's override and the previous default is restored on the other monitors. The target expires after two minutes. File URLs can also be dropped directly onto a monitor rectangle. Same on All and Desktop Span selections stay global.

## Resolved plan

`ResolvedWallpaperAssignmentPlan` is the topology-aware view of #52's existing assignment semantics: mode, mirror master, effective source URL, and whether each source is explicit. The visual Displays destination consumes that plan. #52's live-surface and backdrop paths continue to share the same `explicitDisplayURL` / selected-URL resolution and security-scoped bookmark store; this layer formalizes that result for topology-aware callers without replacing SharedVideoHub or duplicating playback policy.

## CI coverage

`DisplayTopologySmoke` uses synthetic one-display, offset two-display, mirrored, and mixed-resolution/scale layouts. It also checks a ColorSync UUID change against the same hardware identity and known docked/undocked arrangement recording. `WallpaperPolicyTests` covers direct-CG -> UUID -> durable-identity migration and recovery under a new session UUID. No physical displays are required for these checks.
