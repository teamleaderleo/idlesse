# Library SQLite catalog

Idlesse keeps wallpaper media external. The SQLite database stores only bounded Library catalog/state: access references, Source-relative paths, catalog metadata, reconciliation observations, favorites, recent/play state, ordered collections, tags, and related metadata.

## Schema and bounds

SQLite schema version 1 contains normalized tables for Sources, Source metadata, entries, entry tags and metadata, favorites, item state, collections, collection weekdays, and ordered collection membership. Entry rows retain stable IDs plus `present`/`missing` availability and the reconciliation observations used by Source rescans.

Indexes cover Source catalog identity, Source-relative path, availability, media type, series/character, tag and metadata lookup, recency, and collection membership. A partial unique index enforces a non-empty Source catalog ID once per Source.

The SQLite file has a 64 MiB hard bound. Existing semantic bounds remain in force: 4,096 source-backed entries, 128 individually bookmarked entries, 32 Sources, 256 favorites, 256 recent records, and 32 collections with 256 ordered references each. The JSON compatibility/recovery file is capped at 4 MiB. Security bookmarks remain capped at 16 KiB.

No media, poster pixels, decoded frames, or transcoded assets enter SQLite.

## Migration

Older Library JSON is the deterministic migration source and retained recovery snapshot. A migration proceeds in this order:

1. Decode the bounded JSON catalog and run the same semantic validation used by normal Library mutations.
2. Build a sibling SQLite candidate in one transaction, preserving stable IDs, Source/entry/collection ordering, timestamps, present/missing state, reconciliation observations, metadata, tags, favorites, recents, and playback settings.
3. Reopen the candidate, enforce database and row bounds, run SQLite `quick_check` and foreign-key verification, reconstruct the complete in-memory catalog, and require semantic equality with the validated JSON source.
4. Synchronize and publish the candidate database, then write the small versioned backend selector last.

JSON remains authoritative until step 4 completes. Once the selector is published, SQLite owns subsequent mutations transactionally and the retained JSON file becomes a historical recovery snapshot. Idlesse does not dual-write both formats.

Writes use full synchronous durability, a bounded busy timeout, foreign-key enforcement, and the catalog-level validation performed before persistence.

## Recovery

When a selected SQLite database fails schema, integrity, size, or semantic verification and the retained JSON snapshot is still valid, Idlesse opens that JSON snapshot in recovery mode. The next successful Library mutation may build and verify a fresh SQLite candidate. An existing invalid database is retained as a diagnostic `.corrupt` backup while the replacement is published.

An unknown backend-selector version fails closed instead of guessing a format. Candidate publication failure leaves the existing selected database restorable and does not promote an unverified candidate.

## Deterministic support export

`SceneLibraryStore.debugExportData()` produces deterministic sorted-key JSON. It includes stable IDs and ordering, Source metadata, entry metadata/tags, availability and reconciliation observations, favorites, recent timestamps, collections, playback settings, and base64 access references. Dictionary-backed metadata is emitted in sorted key order and dates use a deterministic reference-date number, so equivalent catalogs export byte-for-byte identically.

## Validation coverage

Automated checks cover exact JSON-to-SQLite round trips, schema/index presence, stable ordering and IDs, tombstones, metadata and tags, historical JSON retention after SQLite activation, deterministic debug export, corrupt-database fallback and rebuild, unknown-selector failure, and the existing Source reconciliation suite including 4,096-entry diffs and bounded digest containment.

🧱 Quarry
