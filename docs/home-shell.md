# Home window ownership

Idlesse now treats the Library-owned window as the primary application window. `HomeWindowController` installs a native AppKit source-list split view around the existing Library content **inside the Library's original `NSWindow`**. `AppSettingsController.installLibrary(_:)` remains only as a compatibility entry point for older callers: it recovers the owning `SceneLibraryController` from the view's window, creates Home, and never reparents that view into Settings.

## Destinations

Home exposes Library and Displays as first-class destinations. Favorites, Recently Opened, and saved Collections reuse the Library's existing filter/sort controls so imports, Sources, collection membership/order, schedules, search, selection, previews, drag/drop, and Studio handoff keep one implementation. The persistent toolbar shows the active wallpaper, previous/pause/next controls, the current display destination, and collection-rotation status when active.

Home owns the desktop Files/Widgets controls. The Displays content accepts an optional reusable `NSViewController` plus activation callback. When #31 is present, Home embeds that controller's own view directly and keeps the desktop controls below it. Home never extracts a `contentView` from the standalone Displays window. Until the #31 dependency lands, the Phase-1 Same-on-All summary remains the fallback.

This seam lets #31's visual `DisplayAssignmentViewController` serve both Home and the existing standalone #52 command path with one implementation: the standalone controller is a thin window wrapper, while Home owns a separate destination-controller instance.

## Settings

Settings is a separate preferences window. Playback, automation, screen-saver, and advanced runtime preferences stay there; Library navigation, display targeting, desktop visibility, and Now Playing live in Home. The application-menu **Settings…** command is retargeted to the preferences window when `AppSettingsController` is created.

## Regression coverage

`Tests/HomeShellContractTests.py`, run by `test.sh`, protects the core ownership rule, expected Home destinations/controls, the reusable Displays destination seam, Home-owned panel presentation, and Now Playing thumbnail caching. `HomeWindowController.smokeTest()` also provides deterministic AppKit shell assertions for harnesses that instantiate the production controller.
