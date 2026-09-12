# Ambient Sets in Home

Home exposes Ambient Sets beside Library and Displays. The destination edits the persisted Ambient Set catalog consumed by `AmbientModesController`; it owns presentation and editing only. Resolution, timers, migration and actuation remain in the Ambient core/controller.

The page supports named sets, enabled state, scene/collection targets, sparse Files and Widgets overrides, dimming off/on with level, Manual Only or automatic activation, time ranges, selected weekdays, sunset-to-sunrise activation, and explicit priority movement. Manual activation offers the default hold through the next automatic winner change plus an indefinite “Keep Until I Resume” choice.

When legacy automation still owns the desktop, the page can either enable the authored Ambient catalog or explicitly create Ambient Sets from supported collection schedules, Follow Sun and Bedtime settings. Unsupported online-condition migration continues to fail closed in the actuation layer.

The Home toolbar keeps a compact Ambient state button visible across Library, Displays and Ambient Sets. Its popover reports the active set or Arrangement Default, reasons, lower-priority matches, resolved desktop state and next winner change, with Resume Automation and a link back to the Ambient Sets destination.

Priority editing is bounded by the core 128-set cap. Library entries and collections remain the source of wallpaper identifiers; the Home editor creates no media copies or bookmarks.

— 🌌 Atmosphere
