# Bedtime display

Wallpaper → Bedtime Display offers an adjustable software shade (20–98%), Dim Now,
and an optional daily interval using local clock time. An overnight interval such
as 22:00–07:00 crosses midnight; equal endpoints disable the interval. The schedule
is off by default and only runs while Idlesse is open.

One click-through black window covers each attached screen, below the system menu
bar. The moon status item restores the display. Opening the settings also restores
it before showing the controls. Quit removes the shade. No hardware brightness,
display sleep, power assertions, or desktop files are changed.

Manual overrides last until the next schedule boundary. With scheduling disabled,
Dim Now lasts until Restore or quit. Manual state is not restored after launch.
The scheduler checks every 30 seconds (with a five-second timer tolerance), and
reevaluates on wake/session changes. Display changes recreate the shade windows.

Wallpaper playback pauses while shaded, preserving the user's own pause setting.
This reduces wallpaper animation work, but the shade does not turn off an LCD
backlight or promise the energy savings of display sleep. System UI above the
shade remains visible. Exclusive fullscreen behavior needs separate validation.

Validation: compiled app; native settings → 98% → Dim Now exercised. Core Graphics
reported two shade windows at alpha 0.98 matching the built-in and external screen
bounds. Schedule boundary cases are part of the wallpaper smoke suite. A per-window
app screenshot excludes the shade, so it is not evidence of final display brightness.

Desktop clutter is separate: macOS Desktop & Dock settings can hide desktop items
without moving the files. Idlesse does not rewrite Finder preferences or restart Finder.
