# Idlesse Library

Open Library from the preview window or Wallpaper menu (Command-L).

- Six bundled scenes: Undertow, Fireflies, Ripple, Audio Aurora, Aurora, Breathing Aurora.
- Search by name; filter built-in/imported/favorites; sort by name or recently opened.
- Use Collections → New Collection to create a named group. Select scenes in All
  Scenes, then use Collections → Add to to assign them. Named collections appear
  in the filter menu. Within a collection, the same menu offers rename, delete,
  and removal of the selected scene. These operations never delete source media.
  Up to 32 collections hold up to 256 distinct scene references each; old indexes
  open with no collections. Names must be unique, ignoring case.
- In a collection, choose Play Collection in Order or Shuffle Collection. Playback
  begins immediately and changes every 5, 15, 30 (default), or 60 minutes. Ordered
  playback follows membership insertion order, independent of the Library sort.
  Shuffle exhausts the collection before repeating and avoids an immediate repeat
  between cycles. Stop Collection Rotation, a manual wallpaper choice, or stopping
  the wallpaper ends rotation. Closing Library leaves rotation running.
  Each collection remembers its interval and ordered/shuffle preference.
  Manually started playback is session-only.
  Missing references are omitted; load failures keep the existing wallpaper and
  the next timer tick tries the next member. There is no catch-up burst after sleep.
- Playback & Daily Schedule… provides native time pickers, interval and shuffle
  controls. Enable one daily local-time range per collection; overnight ranges work.
  Overlapping ranges and equal start/end times are rejected. Schedules resume when
  the app launches and are evaluated every 30 seconds (plus timer tolerance).
  Manual selection or Stop suppresses automatic playback through the current
  window; the next boundary resumes it. Outside scheduled ranges, the last
  wallpaper remains displayed without collection rotation. Bedtime remains separate.
  No app auto-launch or system wake is installed. A single-scene schedule can use
  a collection containing one scene.
- Select a scene for a still poster. Double-click or Use on Desktop applies it.
- Open in Studio edits imported packages. Built-ins always become untitled drafts.
- Make a Copy in Studio starts a draft without overwriting its source.
- Remove from Library removes the reference and favorite/recent metadata, never the media.
- Drop supported scene/media files onto the scene list to import references through
  the same pipeline as Add Scenes. Unsupported dropped files are ignored.
- Adding scenes clears the search, opens Imported, and selects the first added scene.
  Each file is attempted independently; failed imports are reported together while
  successful references remain available. Double-clicking empty list space does nothing.

Imported files stay in their existing folder, including cloud-backed folders. The
index keeps security-scoped bookmarks under Application Support/Idlesse/Library,
with up to 128 imports and a 1 MiB index limit. A corrupt index is preserved and
reported, not overwritten. A moved/unavailable file can be re-added through the picker.

Posters are generated only for the selected scene. All compositions
are rendered at scene time 2 seconds with pointer/audio grants off, then their GPU
resources are released. Video frames are decoded at the same preview time and
composited with layers, masks, blending, and effects. Authored video-following uses
scene transport time; ordinary looping video uses elapsed preview time.
Studio supplies the moving composition. This is a still-preview library,
not a grid of continuously playing wallpapers.

The memory cache holds at most eight 512-square posters (about 8 MiB pixel data).
There is no disk thumbnail cache or original-media duplication. Renderer working
memory uses the existing scene budgets during generation. Selecting a scene or
reopening Library checks its revision before reusing a poster. Packages use bounded
JSON and file metadata revisions; raw media uses modification time and size.
Revision checks run off the main thread, without a background folder scan or timer.
Edits during generation discard the result. Refresh Preview forces regeneration. Closing the Library cancels its request and clears
the image cache.

Still missing: weekday rules, collection reordering. Imported
cloud-backed media may need to download when explicitly selected for preview.

Validation includes index round trips/removal preservation, generated Metal posters,
favorite filtering, empty searches, and built-in routing to a Studio draft. The
offscreen UI capture exercises layout but cannot fully reproduce macOS glass-control
appearance; live UI validation remains separate from those tests.

## Wallpaper transitions and shared canvases

The wallpaper menu offers Instant or a 0.5/1/2-second crossfade. A replacement is prepared first; the outgoing scene pauses during the fade and is released at completion. Rapid selection, pause, bedtime, sleep, display changes, and Stop finish the transition immediately. Reduce Motion uses instant switching. Instant remains the default.

Studio Playback offers Per Display and Span Desktop. V19 saves `canvas: desktopSpan`; each wallpaper surface views its rectangle within the union of connected display frames (in macOS logical points). Pointer bindings use that same union when pointer access is enabled. Gaps and unequal monitor sizes are preserved. Studio and exports show the entire scene in their own canvas aspect ratio. Video players still follow the existing approximate clock behavior.
