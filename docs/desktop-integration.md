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
