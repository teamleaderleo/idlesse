#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
home = (root / "Sources/Harness/HomeWindowController.swift").read_text()
settings = (root / "Sources/Harness/AppSettingsController.swift").read_text()
displays = (root / "Sources/Harness/DisplayAssignmentController.swift").read_text()
modes = (root / "Sources/Wallpaper/AmbientModesController.swift").read_text()
policy = (root / "Sources/Wallpaper/AmbientSetActuationPolicy.swift").read_text()
plan = (root / "Sources/Wallpaper/PersistedWallpaperAssignmentPlan.swift").read_text()
transaction = (root / "Sources/Wallpaper/AmbientLegacyScheduleTransaction.swift").read_text()
wallpaper_plan = (root / "Sources/Wallpaper/WallpaperDisplayPlan.swift").read_text()

# One primary product path: Library/Home, real Displays, Ambient Sets, status.
assert '.group("Idlesse"), .library, .displays, .ambient' in home
assert "DisplayAssignmentViewController(wallpaper: wallpaper)" in settings
assert "displaysDestinationController: displays" in settings
assert "AmbientSetsHomeController(modes: modes" in home
assert "ambientStatusButton" in home and "showAmbientStatus" in home

# The permanent display seam owns Arrangement Default updates. Background screen
# refreshes rebuild UI without being mistaken for a user edit, and #52's old
# standalone entry forwards into Home after bootstrap.
for token in ["var onArrangementChange", "onArrangementChange?()"]:
    assert token in displays, token
schedule_refresh = displays.split("private func scheduleTopologyRefresh", 1)[1].split("private func rebuild", 1)[0]
assert "onArrangementChange" not in schedule_refresh
assert "displays.onArrangementChange = { [weak modes]" in settings
assert "static var homePresenter: (() -> Void)?" in displays
assert "DisplayAssignmentController.homePresenter = { [weak home]" in settings
assert "if let homePresenter = Self.homePresenter" in displays

# Arrangement Default stores #70's mode plus durable per-display assignments.
for token in ["var mode: DisplayAssignmentMode", "var assignments: [Assignment]", "baseBookmark"]:
    assert token in plan, token
assert "persistedDisplayAssignmentPlan" in wallpaper_plan
assert "applyPersistedDisplayAssignmentPlan" in wallpaper_plan
assert "wallpaperPlan: PersistedWallpaperAssignmentPlan" in policy
assert "wallpaperBookmark" in policy  # one-time decode compatibility only

# #73 review regressions: real dimming, relaunch manual selection, and atomic
# scheduler transfer all have one explicit implementation now.
assert "ignoreNextCommittedSelection" not in modes
manual = modes.split("func adoptManualSelection", 1)[1].split("private func evaluateLegacyModes", 1)[0]
assert "applyManualOverrides" in manual
assert "resolvedDimmingState" in modes
assert "applyResolvedDimming(snapshot.dimming)" in modes
assert "AmbientLegacyScheduleTransaction.suspend" in modes
assert "AmbientLegacyScheduleTransaction.restore" in modes
assert "setPlayback(" not in modes
assert "data.write(to: file, options: .atomic)" in transaction

# Cutover changes Ambient sets + hold together; visible Settings no longer owns
# automation controls. Historical automation entry points route into Ambient Sets.
store = (root / "Sources/Wallpaper/AmbientSetStore.swift").read_text()
assert "func replaceCatalog" in store
assert "replaceCatalog(AmbientSetCatalog(sets: sets, manualHold: nil))" in modes
settings_ui = settings.split("private func installContent", 1)[1]
assert '("Automation",' not in settings_ui
for stale in ["Schedule dimming", "Follow the sun", "Weather scenes", "Choose night wallpaper"]:
    assert stale not in settings_ui, stale
assert "if requested == 1, let home" in settings
assert "home.presentAmbientSets()" in settings
assert 'item.title = "Ambient Sets…"' in settings
assert "#selector(openAmbientSetsFromMenu(_:))" in settings

# The Library view remains owned by its Library window. Settings receives the old
# install call only as a bootstrap signal and never reparents Library into a tab.
install = settings.split("func installLibrary", 1)[1].split("/// Historical callers", 1)[0]
assert "item.view = view" not in install
assert "tabs.addTabViewItem" not in install
assert "library.hostWindow = library.window" in install

# Home Pause follows WallpaperController's animation-aware validator instead of
# merely checking for any selected URL.
assert "wallpaper.validateMenuItem(pauseValidation)" in home
assert "pauseButton.isEnabled = url != nil" not in home

print("Unified Idlesse product contract passed")
