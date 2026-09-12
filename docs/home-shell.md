# Home window ownership

Idlesse now treats the Library-owned window as the primary application window. `HomeWindowController` installs a native AppKit source-list split view around the existing Library content **inside the Library's original `NSWindow`**. `AppSettingsController.installLibrary(_:)` remains only as a compatibility entry point for older callers: it recovers the owning `SceneLibraryController` from the view's window, creates Home, and never reparents that view into Settings.

## Destinations

Home exposes Library and Displays as first-class destinations. Favorites, Recently Opened, and saved Collections reuse the Library's existing filter/sort controls so imports, Sources, collection membership/order, schedules, search, selection, previews, drag/drop, and Studio handoff keep one implementation. The persistent toolbar shows the active wallpaper, previous/pause/next controls, the current display destination, and collection-rotation status when active.

The Displays destination owns desktop task controls (Files, Widgets, and Same on All Displays). Issue #31 replaces this Phase-1 summary surface with the visual topology/assignment model while preserving the destination and Home ownership.

## Settings

Settings is a separate preferences window. Playback, automation, screen-saver, and advanced runtime preferences stay there; Library navigation, display targeting, desktop visibility, and Now Playing live in Home. The application-menu **Settings…** command is retargeted to the preferences window when `AppSettingsController` is created.

## Regression coverage

`Tests/HomeShellContractTests.py`, run by `test.sh`, protects the core ownership rule and expected Home destinations/controls. `HomeWindowController.smokeTest()` also provides deterministic AppKit shell assertions for harnesses that instantiate the production controller.
