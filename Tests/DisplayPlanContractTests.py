#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
wallpaper = (root / "Sources/Wallpaper/WallpaperController.swift").read_text()
plan = (root / "Sources/Wallpaper/WallpaperDisplayPlan.swift").read_text()
displays = (root / "Sources/Harness/DisplayAssignmentController.swift").read_text()

make = wallpaper.split("private func makeSurfaces", 1)[1].split("/// Remember the user's plain wallpaper", 1)[0]
backdrop = wallpaper.split("private func syncSystemBackdrop", 1)[1].split("private func configureDesktopInteraction", 1)[0]

# #52 remains the runtime authority: live surfaces and matching macOS backdrop
# stills resolve per-display overrides through the exact same durable bookmark
# seam. #70's topology plan is the visual/Ambient projection of that same store.
assert "explicitDisplayURL(for: displayID)" in make
assert "explicitDisplayURL(for: displayID)" in backdrop
assert "func explicitDisplayURL(for displayID: UInt32)" in wallpaper
assert "DisplayAssignmentStore(defaults: resumeDefaults" in wallpaper
assert "let master = topology.master(for: display)" in plan
assert "explicitDisplayURL(for: master.liveID)" in plan
assert "ResolvedWallpaperAssignmentPlan" in plan

# The temporary request cache from #70 became redundant once #52's durable store
# survived the reconciliation. Keep that adapter gone instead of maintaining two
# assignment owners with independent invalidation lifecycles.
assert "DisplayPlanCache" not in plan
assert "sharedDisplayAssignmentPlan" not in plan
assert "invalidateSharedDisplayAssignmentPlan" not in plan

# Visual Displays remains one reusable controller, with the old standalone
# command reduced to a compatibility forwarder after Home has bootstrapped.
assert "final class DisplayAssignmentViewController" in displays
assert "static var homePresenter: (() -> Void)?" in displays
assert "if let homePresenter = Self.homePresenter" in displays

print("display assignment ownership contract passed")
