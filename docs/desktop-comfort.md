# Settings

Open **Idlesse → Settings…** or press **⌘,**. The same window is available from
the preview toolbar and wallpaper menu-bar menu. Library and Settings share this
sidebar window. The header reports wallpaper playback state and provides Pause /
Resume. Choosing a scene keeps the browser open. Changes apply immediately. Idlesse opens here on launch; the screen saver preview
is available separately from the Wallpaper menu.

- **Wallpapers:** Library, animated media imports, collections, previews and Use on Desktop.
- **Playback & Desktop:** frame rate and crossfade. Desktop visibility stays in the sidebar on every page.
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
# Persistent clean desktop

Uncheck **Show on Desktop → Files** in Idlesse's sidebar while a wallpaper is
playing. This now enables Idlesse's own clean desktop surface, rather than
macOS's hide-until-click setting. The same command is in the Wallpaper menu.

The existing wallpaper windows move just above the desktop icon layer. They
handle clicks, so invisible Finder icons cannot receive accidental double-clicks.
The clean cover reuses the running renderer. Separately, a bounded offscreen
render prepares the system wallpaper still once per successful scene selection.

- Left click requests macOS Show Desktop via Mission Control's `1` argument.
- Right click / Control-click opens Idlesse's native context menu: Change
  Wallpaper, Open Desktop Folder, Show / Restore Windows, and visibility controls.
- This is an Idlesse context menu, not a complete replica of Finder's menu.
- Re-enabling Files returns the wallpaper to its normal click-through layer.
- Stopping/quitting Idlesse removes the cover. The mode is restored with playback.
- No file is moved, renamed, hidden with file flags, or removed. Finder is not
  restarted or disabled. Existing macOS icon visibility preferences are unchanged.
- No active wallpaper means no cover; the sidebar Files control is disabled.

The implementation relies on desktop window levels and Mission Control behavior
that need continued qualification across Spaces and macOS versions. It is a
local experimental replacement for the unsuccessful system visibility toggle.

## Desktop widgets

Widgets still controls macOS `StandardHideWidgets`. It is not a promise that
widgets remain hidden during Show Desktop. Stage Manager is separate. The
preference is documented by [WidgetToggler](https://github.com/sieren/WidgetToggler).
Independent visible widgets above the clean wallpaper layer are not qualified.

## Verification

Build/signature and wallpaper/Library/export/restart checks passed. Both live
surfaces were observed above Finder's icon layer. Unit checks verify layer
switching, renderer reuse and local left-click dispatch on an unshown window.
The UI driver cannot target these low-level wallpaper windows, including via
exposed screen coordinates. Real right-click and repeated Show Desktop behavior
therefore remain unverified; do not describe them as passed physical tests.

## Focus and underlying macOS wallpaper

Desktop surfaces are non-activating NSPanel windows. They still receive desktop
mouse actions but should not make Idlesse the active app on a normal click.

The interactive host sets a matching SDR JPEG underneath each live surface,
rendered once per successful scene selection, capped at 1280 pixels on the long
edge. This replaces the previous macOS wallpaper selection so menu-bar materials
and Show Desktop regions use matching artwork instead of an unrelated image.
Two alternating files per display avoid unbounded storage and stale URL caching.
Preparation is cancellation/generation guarded and skipped by test controllers.
The still remains after Stop/Quit as a fallback; the old macOS shuffle collection
is not automatically reconstructed. It is a representative frame, not a live
frame-synchronized menu-bar background. Audio/pointer inputs are not granted to
the offline renderer.

2026-09-10 follow-up: installed non-activating panels and verified both macOS
wallpaper URLs point to generated JPEGs (1280×720 and 1280×828, 444 KB total).
Show / Restore Windows was invoked twice through the regular Wallpaper menu:
normal windows moved offscreen and returned; both clean wallpaper surfaces stayed
above Finder's icon layer. Direct desktop pointer delivery/focus remains outside
the UI driver's supported targeting; user reported the initial clean cover works
better and identified activation/menu-bar issues addressed by this follow-up.

### Live menu strip experiment

`IDLESSE_LIVE_MENU_STRIP=1` (or the app preference
`comfort.liveMenuStrip=true`, applied on restart) opts into a narrow Metal
presentation strip at `mainMenu - 1`. It forces the Metal renderer for that
process. The strip copies the top rows of the existing compositor drawable into
a two-drawable CAMetalLayer on the same command buffer. It creates no second
video player, performs no CPU pixel readback, and writes no wallpaper frames to
disk. The matching system-wallpaper still remains the fallback.

This is **not a supported user setting yet**. The strip ignores mouse events and
uses a nonactivating panel. Native menu-background visibility, menu contrast,
auto-hide/full-screen behavior, Spaces, crossfade opacity, and drawable-acquisition
latency still need qualification before enabling it in the installed app.
In particular a successful GPU copy does not establish that the native menu bar
shows those pixels. A stalled strip drawable can delay the main-thread draw, so
this path must remain opt-in until timing has been measured under occlusion.

The desktop qualification report includes `menuStripFrames` (submitted copies,
not presented frames). A local test can run with:

```sh
IDLESSE_LIVE_MENU_STRIP=1 build/Idlesse.app/Contents/MacOS/Idlesse \
  --qualify-desktop Examples/Gradient.idlesse build/menu-strip-report.json 12 1
```

The qualification process removes its surfaces when finished and does not change
the selected wallpaper or system background. It exercises synthetic lifecycle
transitions, not physical sleep or display hotplug.

Local validation (2026-09-10): debug build on the two attached displays completed
40 seconds of Gradient playback with 2,094 / 2,109 strip copies submitted.
Synthetic pause, overlapping suspension/session states, suspended selection,
failed replacement, and teardown passed; final surface count was zero.
Wallpaper, Library, export/cancellation, and restart-recovery smoke tests passed.
These counts are not visible menu-bar FPS. The test process could not be selected
by the UI inspection tool, so composite menu-bar appearance remains unverified.
