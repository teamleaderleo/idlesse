# Shared display assignment plan

The live desktop surfaces and macOS system-backdrop stills resolve per-display wallpaper policy through one immutable request-scoped `ResolvedWallpaperAssignmentPlan`.

`WallpaperController.sharedDisplayAssignmentPlan(request:desktopSpan:)` snapshots the current `DisplayTopology`, assignment mode, mirror-master relationships, and explicit per-display bookmark overrides. Its cache key is the controller identity, selection/rebuild request generation, topology signature, and `DisplayAssignmentMode`. The cache is hard-bounded to 16 entries and does not retain `WallpaperController`.

`makeSurfaces(playable:clock:request:)` consumes that snapshot when choosing each display's effective scene. `syncSystemBackdrop(scene:sourceURL:request:)` consumes the same snapshot when choosing each display's still. Neither loop independently resolves per-display bookmark overrides, so renderer surfaces and backdrop stills use the same policy snapshot for one request.

Assignment, Same-on-All, and screen-parameter changes can rebuild under the same generation. `rebuild()` invalidates that generation's cached plan before surface recreation; the following backdrop sync therefore receives the fresh snapshot produced by the rebuilt live surfaces. A new Library selection increments the generation and naturally receives a distinct plan.

The plan carries assignment policy only. `SharedVideoHub` remains unchanged and continues to provide the single shared decoder path whenever one scene is shared across displays. Per-display overrides keep their existing independent rendering behavior.

`Tests/DisplayTopologyTests.swift` protects durable device/slot identity and reconnect behavior, while `Tests/WallpaperPolicyTests.swift` protects assignment persistence and migration alongside the coverage policy.

## Named variants

Each durable per-display assignment can carry an optional requested scene-variant UUID beside its bookmark. Existing bookmark-only assignments decode as Default. Reconnect migration mirrors the UUID through the same durable assignment identity, and the UUID remains stored even if the scene temporarily lacks that variant so the assignment can be repaired later.
