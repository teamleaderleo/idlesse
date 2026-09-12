#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
wallpaper = (root / "Sources/Wallpaper/WallpaperController.swift").read_text()
plan = (root / "Sources/Wallpaper/WallpaperDisplayPlan.swift").read_text()

make = wallpaper.split("private func makeSurfaces", 1)[1].split("private func retainSurfaceScope", 1)[0]
backdrop = wallpaper.split("private func syncSystemBackdrop", 1)[1].split("private struct BackdropPlan", 1)[0]
rebuild = wallpaper.split("private func rebuild()", 1)[1].split("// MARK: - Matching system wallpaper stills", 1)[0]

# Live surfaces and macOS backdrop stills must consume the same immutable,
# request-scoped assignment snapshot. Per-display bookmark resolution stays in
# the plan resolver instead of being recomputed independently in either loop.
assert "sharedDisplayAssignmentPlan(" in make
assert "sharedDisplayAssignmentPlan(" in backdrop
assert "explicitDisplayURL(for:" not in make
assert "explicitDisplayURL(for:" not in backdrop
assert "assignmentPlan.assignment(for:" in make
assert "assignmentPlan.assignment(for:" in backdrop

# Assignment/screen-mode refreshes reuse the generation, so rebuild must retire
# that request's old snapshot before makeSurfaces creates a fresh one.
assert "invalidateSharedDisplayAssignmentPlan(request: generation)" in rebuild
assert "maxEntries = 16" in plan
assert "topologySignature" in plan and "mode: DisplayAssignmentMode" in plan

print("display assignment plan contract passed")
