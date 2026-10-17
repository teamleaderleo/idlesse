# Library SQLite catalog

Idlesse keeps wallpaper media external. The catalog backend stores access references, Source-relative paths, Source metadata, reconciliation observations, favorites, recents, ordered collections and playback settings.

## Why SQLite now

The concurrent-safe JSON implementation remains an acceptable bounded compatibility and recovery format. At current catalog limits, JSON size and decode time alone do not force a migration.

SQLite earns the migration because Library state now changes along independent ownership lines. Favorite/recent/collection mutations should not rewrite the whole catalog; Source reconciliation needs atomic multi-row commits; future collection selections and stacks need indexed relationships. The SQLite backend therefore uses row/relationship deltas instead of the whole-catalog `DELETE` + reinsert approach from historical PR #78.

## Activation and authority

A Library without a backend selector reads JSON. Read-only opens leave it there. The first mutation performs migration while holding the same sibling `index.json.lock` used by the JSON safety layer:

1. Decode and semantically validate the current JSON catalog.
2. Build `index.sqlite3.candidate` in one SQLite transaction using schema v2.
3. Run row bounds, foreign-key checking, `quick_check`, and a complete semantic round-trip comparison.
4. Synchronize the candidate, publish it as `index.sqlite3`, and synchronize the Library directory.
5. Write and synchronize `index.backend` containing `sqlite-v2` **last**.
6. Apply the requested mutation as one normal SQLite delta transaction.

Until step 5, JSON is the sole authority. Candidate failure leaves JSON active and usable. Once the selector exists, SQLite is authoritative. Idlesse fails closed on an unknown selector, unsupported schema, oversized database, integrity failure, or semantic read failure; it never silently replaces newer SQLite state with the retained historical JSON.

The pre-migration JSON file remains byte-for-byte unchanged after successful activation. It is migration/recovery evidence and a human-inspectable snapshot, not a dual-write target.

## Concurrent writers

All Store writers, JSON or SQLite, take the same cross-process `flock`. Under that lock a stale store:

1. reads and validates the currently selected catalog;
2. rebases only its local changes onto that current catalog using the existing #119 semantics;
3. validates the result;
4. applies the resulting SQLite row/relationship delta inside `BEGIN IMMEDIATE`.

The SQLite transaction re-reads the complete semantic catalog and requires it to equal the Store's locked current snapshot before changing rows. Deliberate removals still win over stale edits, concurrent favorites/recents/collection changes preserve unrelated work, and #136 reconciliation reviews retain their current-disk fence.

## Destructive recovery

Before a SQLite transaction may drop entries, the existing recovery layer persists:

- a bounded semantic JSON backup of the current selected catalog;
- the bounded Recently Removed ledger, including Source evidence when needed;
- the bounded removal log with process/transaction identity.

Failure to persist that evidence aborts the destructive commit. Original media is never modified.

## Schema v2

The database is bounded at 64 MiB and has an explicit `PRAGMA user_version = 2`. Main tables cover Sources, entries, tags/provenance, favorites, recents, collections, weekdays and ordered collection items. Indexes cover Source catalog identity/path/availability, media metadata, tags, recency and collection membership.

Presence bits preserve semantically distinct optional values exactly:

- Source metadata: `nil` vs empty dictionary;
- entry provenance: `nil` vs empty dictionary;
- reconciliation observation: `nil` vs a present observation with empty optional fields.

`collection_items` reserves nullable `variant_id` for the collection-selection model tracked in #132. Until that model lands, a populated `variant_id` causes the current reader to fail closed instead of dropping variant intent.

Top-level ordered rows use unique ordinals. Any add/remove/reorder stages existing and changed/new rows in separate temporary ordinal ranges, then compacts every ID to its final position inside the same transaction.

## Mutation policy

High-churn state uses owned rows:

- favorites: insert/delete only changed favorite IDs;
- recents: upsert/delete only changed recent IDs;
- collection changes: update only changed collections and their child relationships;
- entry/source changes: update only affected rows and owned metadata children;
- ordering changes: renumber the affected top-level ordered table transactionally.

Every mutation finishes with row-bound, foreign-key, integrity and complete semantic round-trip verification before commit.

## Debug/export

`SceneLibraryStore.debugExportData()` emits deterministic sorted-key JSON (`idlesse-library-debug-v2`) containing every durable catalog field, stable ID and order, explicit optional-value presence, favorites, recents and collections. Access references are represented as base64.

## Test isolation

All `--smoke*` app processes resolve the canonical Library to a per-process temporary index before backend selection, so a smoke migration can only create SQLite files beside that scratch index. `IDLESSE_LIBRARY_INDEX` remains the explicit scratch override.

`LibrarySafetyTests` run with `IDLESSE_LIBRARY_BACKEND=json` to keep adversarial coverage of the legacy fallback. Normal Library/reconciliation tests and `LibrarySQLiteTests` exercise automatic migration and the selected SQLite backend.

🧰 Vault
