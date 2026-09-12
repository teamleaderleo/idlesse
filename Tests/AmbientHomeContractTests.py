#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
home = (root / "Sources/Harness/HomeWindowController.swift").read_text()
ambient = (root / "Sources/Harness/AmbientSetsHomeController.swift").read_text()

# Home owns one Ambient Sets destination and one always-visible status control.
for token in [
    "case ambient",
    'case .ambient: return "Ambient Sets"',
    'case .ambient: return "circle.lefthalf.filled"',
    '.group("Idlesse"), .library, .displays, .ambient',
    "ambientStatusButton",
    "showAmbientStatus",
    "Resume Automation",
    "presentAmbientSets()",
    "AmbientSetsHomeController.chipTitle",
]:
    assert token in home, token

# The destination edits the production catalog instead of carrying a UI-only copy.
for token in [
    "modes.replaceAmbientSets(sets)",
    "modes.activateAmbientSet(id:",
    "modes.resumeAutomaticAmbientSets()",
    "modes.migrateLegacyToAmbientSets()",
    "modes.enableAmbientSets(sets)",
    "modes.disableAmbientSets()",
    "AmbientActivation(timeRange:",
    "weekdays:",
    "solar: solarButton.state == .on ? .night : nil",
    ".scene(entry.id)",
    ".collection(collection.id)",
    "set.overrides.filesVisible",
    "set.overrides.widgetsVisible",
    "set.overrides.dimming",
    "moveSelected(by:",
    "registerForDraggedTypes([Self.dragType])",
    "acceptDrop info: NSDraggingInfo",
    "Use Until Next Change",
    "Keep Until I Resume",
]:
    assert token in ambient, token

print("Ambient Sets Home contract smoke passed")
