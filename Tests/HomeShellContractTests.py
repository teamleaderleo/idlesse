#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
home = (root / "Sources/Harness/HomeWindowController.swift").read_text()
settings = (root / "Sources/Harness/AppSettingsController.swift").read_text()

# Library keeps its original window. Settings performs one-time bootstrap only;
# Home receives the Library controller and never installs Library as a Settings tab.
install = settings.split("func installLibrary", 1)[1].split("/// Historical callers", 1)[0]
assert "item.view = view" not in install
assert "tabs.addTabViewItem" not in install
assert "HomeWindowController(" in install
assert "library.hostWindow = library.window" in install

# Smoke the visible product destinations without real monitor/media input.
for token in [
    "NSSplitViewController()",
    '.group("Idlesse"), .library, .displays, .ambient',
    '.group("Library"), .favorites, .recent',
    "NSToolbar(identifier:",
    "Previous wallpaper",
    "Pause wallpaper",
    "Next wallpaper",
    "ambientStatusButton",
    "presentAmbientSets()",
    "wallpaper.presentingWindow = { [weak library] in library?.window }",
    "if standardized != cachedThumbnailURL",
]:
    assert token in home, token

# Home embeds the real #70 controller, while #77's temporary checkbox-only
# Displays page is never used when the app is fully wired.
for token in [
    "displaysDestinationController: NSViewController? = nil",
    "activateDisplaysDestination: (() -> Void)? = nil",
    "activateDisplaysDestination?()",
    "if let destinationController = displaysDestinationController",
    "let destination = destinationController.view",
    "displayDestination.view.superview === home.displaysView",
    "precondition(displayActivated)",
]:
    assert token in home, token
assert "contentView = destination" not in home
assert "DisplayAssignmentViewController(wallpaper: wallpaper)" in settings
assert "displays.onArrangementChange" in settings

# Pause parity uses WallpaperController's existing animation-aware menu validator.
assert "wallpaper.validateMenuItem(pauseValidation)" in home
assert "#selector(WallpaperController.togglePause)" in home

# Settings contains conventional preferences only. Ambient Sets and Displays are
# Home destinations; the historical automation route forwards to Ambient Sets.
settings_ui = settings.split("private func installContent", 1)[1]
assert '("Playback", "play.circle")' in settings_ui
assert '("Screen Saver", "sparkles.tv")' in settings_ui
assert '("Automation",' not in settings_ui
assert "Same wallpaper on all displays" not in settings_ui
assert 'checkboxWithTitle: "Files"' not in settings
assert 'checkboxWithTitle: "Widgets"' not in settings
assert "if requested == 1, let home" in settings
assert "home.presentAmbientSets()" in settings

print("Home shell ownership smoke passed")
