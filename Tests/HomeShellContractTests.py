#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
home = (root / "Sources/Harness/HomeWindowController.swift").read_text()
settings = (root / "Sources/Harness/AppSettingsController.swift").read_text()

# The regression this shell exists to prevent: Library content must stay in the
# Library-owned window instead of becoming a Settings tab.
install = settings.split("func installLibrary", 1)[1].split("func present", 1)[0]
assert "item.view = view" not in install
assert "tabs.addTabViewItem" not in install
assert "HomeWindowController(library:" in install
assert "library.hostWindow = library.window" in install
assert "guard home == nil else { return }" not in install

main = (root / "Sources/Harness/main.swift").read_text()
assert "library.hostWindow = appSettings.window" not in main
assert "library.hostWindow = library.window" in main

library = (root / "Sources/Harness/SceneLibraryController.swift").read_text()
assert "panel.canChooseDirectories = true" in library
assert "Folders become rescan-able Library Sources" in library
assert "self.importSource(directory)" in library

# Smoke the visible shell contract without requiring real monitors/media.
for token in [
    "NSSplitViewController()",
    ".library, .favorites, .recent, .displays",
    ".group(\"Collections\")",
    "NSToolbar(identifier:",
    "Previous wallpaper",
    "Pause wallpaper",
    "Next wallpaper",
    "Same wallpaper on all displays",
    "comfort.toggleDesktopIcons()",
    "comfort.toggleDesktopWidgets()",
    "wallpaper.presentingWindow = { [weak library] in library?.window }",
    "if standardized != cachedThumbnailURL",
]:
    assert token in home, token

# #31 can inject its reusable visual destination without giving Home another
# window's contentView. Until that dependency lands, the Phase-1 display summary
# remains a compatible fallback.
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

# Settings stays preferences-only; display targeting and desktop visibility are
# Home concerns now.
settings_init = settings.split("private func installContent", 1)[1]
assert "Same wallpaper on all displays" not in settings_init
assert "checkboxWithTitle: \"Files\"" not in settings
assert "checkboxWithTitle: \"Widgets\"" not in settings

print("Home shell ownership smoke passed")
