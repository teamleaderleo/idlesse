# Idlesse Library

Open Library from the preview window or Wallpaper menu (Command-L).

- Eight bundled scenes currently ship with the app: Desk Clock, After Hours, Undertow,
  Fireflies, Ripple, Audio Aurora, Aurora, and Breathing Aurora.
- Search by name; filter included/imported/favorites; sort by name or recently opened.
- Import… keeps the existing individual-file flow. Supported media stays in its current
  folder and each individually imported entry retains its own security-scoped bookmark.
  Existing indexes continue to resolve these entries exactly as before.
- Sources… → Add Source… adds a folder catalog. The user grants one folder bookmark,
  Idlesse performs one explicit bounded scan, and matching entries are saved as safe
  relative paths beneath that Source. The scan includes native `.idlesse`, JPEG, PNG,
  HEIC, MP4, and MOV media; it does not transcode files or rewrite the selected folder.
  A Source scan visits at most 20,000 filesystem items and the Library accepts at most
  4,096 source-backed entries total. Scanning ends when the add operation ends; there
  is no background rescan service or folder polling.
- Sources… → Rescan <name>… scans descendants beneath the currently authorized Source
  root, computes a pure reconciliation diff, and presents a review before changing the
  catalog. New, missing, changed, confirmed moved/restored, unchanged, and review-only
  probable moves are summarized separately. Canceling the scan or review leaves the
  current catalog untouched. Apply validates the complete candidate catalog and writes
  it once atomically. Source media remains external and unchanged.
- Reconciliation preserves `Entry.id` when identity survives. Matching order is unique
  Source `catalogID`, exact relative path, then unique content digest evidence already
  present or computed for a small targeted candidate set. Cheap size/type/title/media
  observations can propose probable moves for review; they never transfer identity by
  themselves. Conflicting non-empty catalog IDs at the same path are replacements.
  Ambiguous duplicate and many-to-one cases remain separate until a user confirms an
  unambiguous probable move.
- Missing Source entries are retained as tombstones with their stable ID, last known
  locator, favorite/recent state, and ordered collection membership. Normal Library
  browsing and playback skip them. A later rescan can restore the same ID. Tombstones
  remain inside the bounded catalog until explicitly removed.
- Sources… → Relink <name>… replaces only that Source's folder bookmark. Stable Source
  and entry IDs, relative paths, favorites, recents, collections, schedules, and saved
  ordering remain intact. This is the recovery path after moving or renaming a root
  folder when its bookmark can no longer resolve it. Relink changes the root locator;
  Rescan reconciles descendants beneath a healthy root.
- Sources… → Remove <name>… removes the Source and its entries from the Library catalog.
  Favorites, recent records, and collection membership for those removed entries are
  cleaned from the catalog. Source media and poster files remain untouched.
- Remove from Library removes one entry and its favorite/recent metadata, never media.
  This works for individual imports and entries from a Source.
- Drop supported scene/media files onto the scene list to use the individual import
  pipeline. Unsupported dropped files are ignored.
- Adding individual scenes clears the search, opens Imported, and selects the first
  added scene. Video playability is probed asynchronously. Imports/conversions run
  sequentially in one cancellable batch and refresh the Library once on completion.
  Each file is attempted independently; failed imports are reported together while
  successful references remain available. Double-clicking empty list space does nothing.

## Durable catalog storage

The Library uses SQLite for durable catalog/state storage under Application Support.
Media stays external. The database contains only access references, Source-relative
paths, catalog metadata, reconciliation observations, favorites, recent/play state,
ordered collections, tags, and other bounded Library state.

SQLite schema version 1 contains normalized tables for Sources, Source metadata, entries,
entry tags/multivalue metadata, favorites, item state, collections, collection weekdays,
and ordered collection membership. Entry rows retain stable IDs plus `present`/`missing`
availability and bounded reconciliation observations. Indexes cover Source catalog
identity, Source-relative path, availability, media type, series/character, tag and
metadata lookup, recency, and collection membership. A partial unique index enforces a
non-empty Source catalog ID once per Source.

Older Library JSON remains the migration source and recovery snapshot. The compatibility
reader accepts catalog versions 1 and 2 with the existing semantic bounds. Rich JSON is
capped at 4 MiB while retaining the 4,096 Source-entry limit, 128 individually bookmarked
entries, 32 Sources, 256 favorites/recents, and 32 collections with 256 ordered references
each. The first successful mutation can migrate a valid JSON catalog; callers can also
request migration explicitly.

Migration is deliberately staged:

1. Decode and semantically validate the bounded JSON catalog without rewriting it.
2. Build a sibling SQLite candidate in one transaction, preserving exact stable IDs,
   source/entry/collection order, timestamps, tombstones, metadata, tags, and playback.
3. Reopen the candidate, run SQLite `quick_check` and foreign-key verification, enforce
   row/database bounds, reconstruct the catalog, and require semantic equality with the
   validated JSON source.
4. Synchronize and publish the database, then write the tiny versioned backend selector
   last. The JSON file is unchanged through this switch and remains available for recovery.

After the selector switches, SQLite owns subsequent mutations transactionally and the
JSON snapshot becomes historical. Idlesse never attempts dual writes. If the selected
SQLite database later fails integrity/schema/semantic verification, Idlesse opens the
retained validated JSON snapshot in recovery mode. The next successful Library mutation
can rebuild a candidate SQLite database while preserving the bad database as a diagnostic
backup. An unknown backend-selector version fails closed instead of guessing a format.

The SQLite file has a 64 MiB hard bound in addition to the catalog-level limits. Writes
use full synchronous durability and a bounded busy timeout. Candidate databases and
failed publication leftovers stay within the same Library directory. No media bytes,
posters, decoded frames, or transcoded assets are copied into SQLite.

`SceneLibraryStore.debugExportData()` produces deterministic, sorted-key JSON for support
and verification. It includes stable IDs, ordering, metadata, tags, availability,
observations, favorites, recents, collection playback, and base64 access references.
Dictionary-backed fields are emitted in sorted key order and dates use a deterministic
reference-date number, so equivalent catalogs export byte-for-byte identically.

An entry still uses one of two location forms. An individual import has a security-scoped
`bookmark`. A source-backed entry has `sourceID` plus `relativeMediaPath` and can also
carry `catalogID`, `relativePosterPath`, `series`, `character`, `variant`, `tags`,
`mediaType`, `width`, `height`, `fps`, `duration`, string provenance fields,
`availability` (`present`/`missing`), and reconciliation observations. Observations are
bounded file byte length, modification timestamp, optional digest+algorithm, and a
bounded package revision for `.idlesse` directories. Size/mtime/package observations
identify change candidates; durable identity comes from the reconciliation rules above.

Relative media and poster paths must be non-empty relative paths with no absolute
prefix, empty component, `.` component, or `..` component. Resolution appends the
validated path to the authorized root and checks containment again after resolving
symlinks, so a symlink cannot redirect a catalog entry outside the granted folder.
A missing Source root stays in the catalog and reports a Relink Source… recovery message.
A missing descendant stays as a reconciliation tombstone and reports Rescan Source
recovery when directly resolved.

Security-scoped access has an explicit owner. `SceneLibraryStore.Access` starts access
on the individual file bookmark or Source root bookmark and closes it when the access
object is released or explicitly closed. Thumbnail and selected-poster work retain an
access object for the duration of each read. A source-backed wallpaper or Studio handoff
keeps a Source access object alive beyond URL resolution so asynchronous consumers can
read descendants under the folder grant. The host can release those retained grants
when that wallpaper or Studio source is replaced.

Reconciliation hashing has a hard candidate budget. The default helper examines at most
32 targeted unmatched regular files, at most 8 MiB per file and 64 MiB total, and uses a
whole-file SHA-256 only inside those bounds. A candidate whose resolved path leaves the
Source root is skipped before reading. Large videos are skipped instead of sampled and
promoted to identity evidence. Ordinary rescans therefore depend on catalog IDs, paths,
and cheap observations rather than hashing a large media collection.

Library storage versioning is independent of `.idlesse` scene revisions. This migration
does not change revision 21 scene format.

## Collections and playback

- Use Collections… → New Collection to create a named group. Select scenes in All
  Wallpapers, then use Collections… → Add to to assign them. Named collections appear
  in the filter menu. Within a collection, the same menu offers rename, delete, and
  removal of the selected scene. These operations never delete source media. Names must
  be unique, ignoring case.
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
- Playback & Schedule… provides native time pickers, interval and shuffle controls.
  Enable one local-time range per collection and choose its start days. Overnight ranges
  continue into the following morning; overlaps are checked across the entire week.
  Older daily schedules keep every day enabled. Overlapping ranges and equal start/end
  times are rejected. Schedules resume when the app launches and are evaluated every
  30 seconds (plus timer tolerance). Manual selection or Stop suppresses automatic
  playback through the current window; the next boundary resumes it. Outside scheduled
  ranges, the last wallpaper remains displayed without collection rotation. Bedtime
  remains separate. No app auto-launch or system wake is installed. A single-scene
  schedule can use a collection containing one scene.
- Collections retain saved order. Move Collection Up/Down arranges the collection menu;
  Move Scene Earlier/Later arranges playback. Collection views show playback order,
  regardless of the global sort setting.

## Posters and resource bounds

Select a scene for a still poster. Double-click or Set Wallpaper applies it. Open in
Studio edits imported packages; bundled scenes become untitled drafts. Make a Copy in
Studio starts a draft without overwriting its source. Source entries with an explicit
`relativePosterPath` use that poster for the small list thumbnail while selected-scene
preview still renders the actual composition.

Posters are generated only for the selected scene. All compositions are rendered at
the metadata previewTime (default 2 seconds) with pointer/audio grants off, then their
GPU resources are released. Video frames are decoded at the same preview time and
composited with layers, masks, blending, and effects. Authored video-following uses
scene transport time; ordinary looping video uses elapsed preview time. Studio supplies
the moving composition. This is a still-preview library rather than a grid of
continuously playing wallpapers.

The memory cache holds at most four 1024×576 widescreen posters (about 9 MiB pixel data).
List and grid thumbnails share a separate cache capped at 64 images and 64 MiB. Packages
prefer a baked preview or decodable package asset. Assetless procedural packages then
render one 320×180 compositor probe at metadata `previewTime`, covering shader, particle,
gradient, text, and shape scenes. Thumbnail decoding and probe rendering stay on the
utility thumbnail queue, release renderer resources after each probe, and leave the
existing placeholder in place when generation fails. There is no disk thumbnail cache
or original-media duplication. Renderer working memory uses the existing scene budgets
during generation. Selecting a scene or reopening Library checks its revision before
reusing a poster. Packages use bounded JSON and file metadata revisions; raw media uses
modification time and size. Revision checks run off the main thread. Edits during
generation discard the result. Refresh Preview forces regeneration. Closing the Library
cancels its request and clears the image cache.

Cloud-backed individual media or Source descendants may need to download when explicitly
selected for preview.

Validation covers JSON compatibility decoding and migration, SQLite candidate integrity
and semantic verification, exact ID/order/timestamp preservation, deterministic debug
export, corrupt-database recovery, individual-bookmark round trips, mixed individual and
source-backed catalogs, moved/missing/relinked roots, reconciliation additions/removals/
moves/replacements, ambiguity and review-only relinks, stable-ID state retention,
cancellation/atomic apply, 4,096-entry pure reconciliation, bounded digest work and
symlink containment, traversal rejection, metadata round trips, favorite/recent/
collection preservation, source removal without media deletion, retained catalog limits,
generated Metal posters, bounded particle and shader thumbnail probes, favorite filtering,
empty searches, and bundled-scene routing to a Studio draft. The offscreen UI capture
exercises layout but cannot fully reproduce macOS glass-control appearance; live UI
validation remains separate from those tests.

## Wallpaper transitions and shared canvases

The wallpaper menu offers Instant or a 0.5/1/2-second crossfade. A replacement is prepared
first; the outgoing scene pauses during the fade and is released at completion. Rapid
selection, pause, bedtime, sleep, display changes, and Stop finish the transition
immediately. Reduce Motion uses instant switching. Instant remains the default.

Studio Playback offers Per Display and Span Desktop. V19 saves `canvas: desktopSpan`;
each wallpaper surface views its rectangle within the union of connected display frames
(in macOS logical points). Pointer bindings use that same union when pointer access is
enabled. Gaps and unequal monitor sizes are preserved. Studio and exports show the entire
scene in their own canvas aspect ratio. Video players still follow the existing approximate
clock behavior.