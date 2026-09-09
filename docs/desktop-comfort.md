# Settings

Open **Idlesse → Settings…** or press **⌘,**. The same window is available from
the preview toolbar and wallpaper menu-bar menu. Library and Settings share this
sidebar window. The header reports wallpaper playback state and provides Pause /
Resume. Choosing a scene keeps the browser open. Changes apply immediately. Idlesse opens here on launch; the screen saver preview
is available separately from the Wallpaper menu.

- **Wallpapers:** Library, animated media imports, collections, previews and Use on Desktop.
- **Playback & Desktop:** desktop icons, frame rate, crossfade.
- **Bedtime:** dimming level, daily schedule, Dim Now / Restore.
- **Screen Saver:** opens the existing options as an attached sheet.

# Bedtime display

Settings → Bedtime offers an adjustable software shade (20–98%), Dim Now,
and an optional daily interval using local clock time. An overnight interval such
as 22:00–07:00 crosses midnight; equal endpoints disable the interval. The schedule
is off by default and only runs while Idlesse is open.

One click-through black window covers each attached screen, below the system menu
bar. The crescent status item is labeled **Dimmed**, with Restore Display and
70/90/98% presets. Option-Command-D also toggles dimming while Idlesse is active
(it is not a system-wide hotkey). Settings appear above the shade without restoring
the rest of the desktop; closing Settings preserves dimming, and changing the level does not
discard a manual override. Quit removes the shade. No hardware brightness,
display sleep, power assertions, or desktop files are changed.

Manual overrides last until the next schedule boundary. With scheduling disabled,
Dim Now lasts until Restore or quit. Manual state is not restored after launch.
The scheduler checks every 30 seconds (with a five-second timer tolerance), and
reevaluates on wake/session changes. Display changes recreate the shade windows.

Wallpaper playback pauses while shaded, preserving the user's own pause setting.
This reduces wallpaper animation work, but the shade does not turn off an LCD
backlight or promise the energy savings of display sleep. System UI above the
shade remains visible. Exclusive fullscreen behavior needs separate validation.

Initial validation: native settings → 98% → Dim Now exercised. Core Graphics
reported two shade windows at alpha 0.98 matching the built-in and external screen
bounds. The subsequent labeled controls/settings refinement is built and covered by
the regression suites, but has not been activated on the sleeping user's desktop.
Schedule boundary and daylight-saving picker cases run in `Tests/ComfortTests.swift`.
A per-window
app screenshot excludes the shade, so it is not evidence of final display brightness.


To build and smoke-test changes without replacing a running dimmer's bundle:

```
BUILD_DIR="$PWD/build/next" ./build.sh app
BUILD_DIR="$PWD/build/next" ./test-wallpaper.sh
```
# Desktop icons

**Wallpaper → Show Desktop Icons** mirrors macOS Desktop & Dock → Show items →
On Desktop. The same checked toggle is available in the wallpaper and dimming
menu-bar menus. Uncheck it to hide files without moving or deleting them; check
it to show them again. The setting persists independently of Idlesse.

The toggle keeps Finder's desktop surface enabled, preserving click-wallpaper
to reveal the desktop. It changes WindowManager's `StandardHideDesktopIcons`
preference, not `CreateDesktop=false`, which disables desktop click handling.
Finder restarts when applying the change. Widget visibility, Stage Manager and
the click-wallpaper preference are left unchanged. Controls refresh from the
system preference; Idlesse does not store a competing copy of this setting.
