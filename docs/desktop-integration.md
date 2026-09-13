# Desktop entry points

The app embeds a sandboxed Finder Sync extension, scoped to the Desktop folder.
Its contextual actions open `idlesse://wallpapers` and `idlesse://desktop-icons`.
The app handles icon visibility through DesktopComfortController; the extension
does not modify files or preferences itself.

Apple's Change Wallpaper menu item and Wallpaper settings remain system-owned.
Use Customize Idlesse Wallpaper in the contextual menu for the Idlesse Library.
If missing, check Idlesse Desktop Menu in macOS Finder extensions settings.
Enabling is not sufficient on all locations: the user's iCloud-managed Desktop
was visually tested and does not show these actions, despite the extension being
enabled and running. Do not advertise this as working on iCloud Desktop. Keep
the existing menu-bar controls available; do not disable iCloud or move files.
Development installations must register the containing app and extension.

`idlesse://screensaver` opens and focuses the app's screen saver options.
Repeated requests preserve an existing unsaved sheet. Reopening the app reveals
the Library, including when its window was minimized.

The installed .saver still supplies its native configuration sheet to System
Settings. Rebuilds do not update that installed bundle: use installed-status,
replace it with System Settings closed, and restart the legacy saver host.

Validation: app and saver build; options UI smoke passes; installed signatures
verify; URL opens the options sheet; Finder extension registered, enabled, and
running. On this Tahoe installation the iCloud Desktop background menu was
visually checked and contains no extension actions. Directory comparisons use
normalized paths so a trailing slash cannot reject an otherwise identical target.

## Native wallpaper provider investigation (2026-09-12)

Home now has separate playback, current-wallpaper, and Settings toolbar items.
Previous/Next walks the visible Library scope from the playing URL, independent
of the poster being browsed. Missing/filtered-out playback starts at the scope's
first/last item. The app Settings callback opens preferences, matching the
retargeted Command-comma menu command.

The public `NSWorkspace.setDesktopImageURL` entry point supplies desktop images;
it is not evidence of a public third-party animated wallpaper provider API:
https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)

Phosphene documents a substantially closer integration using the private
WallpaperExtensionKit framework. Its extension is hosted by WallpaperAgent,
appears as a collection in System Settings, and handles lock-screen presentation
and snapshots. This is a useful feasibility reference, not functionality Idlesse
has implemented or tested:
https://github.com/kageroumado/phosphene

A bounded next experiment should use a separate extension target and a synthetic
video. Prove local signing/registration first without requiring a paid certificate;
then verify System Settings discovery, assignment readback, lock/unlock,
sleep/wake, display changes, and restoration to the previous provider. Feed it a
small reference catalog, not a second copy of the media library. Keep app/extension
assignment state explicit so a system wallpaper selection cannot silently disagree
with Idlesse's Now Playing display. Avoid editing Apple's aerial asset files or
WallpaperAgent's private preference store as an integration shortcut.

This turn does not install that extension, replace Apple's providers, or claim
lock-screen synchronization. Finder's iCloud Desktop limitation above remains.
