# Desktop entry points

The app embeds a sandboxed Finder Sync extension, scoped to the Desktop folder.
Its contextual actions open `idlesse://wallpapers` and `idlesse://desktop-icons`.
The app handles icon visibility through DesktopComfortController; the extension
does not modify files or preferences itself.

Apple's Change Wallpaper menu item and Wallpaper settings remain system-owned.
Use Customize Idlesse Wallpaper in the contextual menu for the Idlesse Library.
If missing, enable Idlesse Desktop Menu in macOS Finder extensions settings.
Development installations must register the containing app and extension.

`idlesse://screensaver` opens and focuses the app's screen saver options.
Repeated requests preserve an existing unsaved sheet. Reopening the app reveals
the Library, including when its window was minimized.

The installed .saver still supplies its native configuration sheet to System
Settings. Rebuilds do not update that installed bundle: use installed-status,
replace it with System Settings closed, and restart the legacy saver host.

Validation: app and saver build; options UI smoke passes; installed signatures
verify; URL opens the options sheet; Finder extension registered, enabled, and
running. Actual contextual-menu placement still needs a visual check on Tahoe.
