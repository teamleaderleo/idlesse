# Displays topology and assignment

Issue #31 is layered directly on the assignment runtime from #52. `DisplayAssignmentController` owns presentation; `WallpaperController` remains the authority for applying scenes, security-scoped bookmarks, SharedVideoHub reuse, Desktop Span promotion, and system-backdrop stills.

## Display identity

`CGDirectDisplayID` is a live-session handle only. `DisplayIdentity` records the ColorSync display UUID plus vendor/model/serial, built-in state, physical millimetres, and the localized display name. A hardware fingerprint is the canonical persistence key; ColorSync UUID remains the exact session alias used by #52.

`DisplayIdentityStore` keeps at most 32 recently seen identity records. Reconnect matching first rejects known serial/vendor/model conflicts, then ranks exact UUID and serial-backed hardware matches, followed by vendor/model plus physical characteristics. A match must be unique. Equal best candidates are rejected, so two identical serial-less displays cannot inherit one another's assignment. Truly indistinguishable siblings also receive a deterministic relative-position suffix instead of persisting their current numeric CG handle.

`DisplayAssignmentStore.reconcile(identityKey:previousIdentityKey:persistentID:legacyDisplayID:)` migrates the existing #52 UUID/direct-CG assignment keys onto the current canonical identity after that unique match. A reconnected display can therefore seed a newly issued session UUID from the saved identity. The synthetic recovery test uses a saved UUID A, current UUID B, and a small EDID-size drift to exercise the production path.

## Topology

`DisplayTopology` captures real AppKit frames, backing scale, pixel resolution, main-display status, and Core Graphics mirror-master relationships. `normalizedFrames(in:)` scales the union of those real frames into the visual canvas while preserving negative origins, vertical offsets, gaps, portrait/landscape proportions, and mixed resolutions.

Mirrored displays retain their own snapshot for diagnostics but resolve wallpaper assignment through the mirror master. Desktop Span remains a global scene mode and disables Same on All / Per Display switching while active.

Dock and cable changes often generate several intermediate screen-parameter notifications. Displays coalesces them for 300 ms before identity reconciliation or assignment restoration so a transient one-monitor or half-docked state cannot drive recovery decisions.

## Known arrangements

`KnownDisplayArrangementsStore` keeps a deterministic recent-first history capped at 16 arrangements with at most 16 member identities each. Observation alone can refresh `lastSeen` for an exact known signature and never creates a new profile. An unknown settled topology remains **Unremembered Setup** until the user presses **Remember Setup**. A lone built-in panel then begins as **MacBook Only**; multi-display layouts begin as **Desk Setup**. Profiles describe remembered arrangements; macOS continues to own physical monitor placement.

## Library assignment flow

Displays contains no second Library catalog. Selecting **Choose in Library…** opens the real Library. In Per Display mode, the next Library **Set Wallpaper** is captured as the selected monitor's override and the previous default is restored on the other monitors. The target expires after two minutes. File URLs can also be dropped directly onto a monitor rectangle. Same on All and Desktop Span selections stay global.

## Resolved plan

`ResolvedWallpaperAssignmentPlan` is the topology-aware view of #52's existing assignment semantics: mode, mirror master, effective source URL, and whether each source is explicit. The resolver also accepts a candidate base URL/Desktop Span state so one selection transaction can resolve before `selectedURL` is adopted. The visual Displays destination consumes this plan while SharedVideoHub remains the only shared-video playback path.

## CI coverage

`DisplayTopologySmoke` uses synthetic one-display, offset two-display, mirrored, and mixed-resolution/scale layouts. It covers UUID changes, unique reconnect matching, identical serial-less ambiguity, explicit arrangement persistence, and known docked/undocked matching. `DisplayTopologyTests` exercises an actual UUID-A -> UUID-B assignment migration with changed EDID millimetres. `WallpaperPolicyTests` retains #52's direct-CG -> UUID compatibility migration coverage. No physical displays are required for these checks.
