# Library stacks

Library stacks group related catalog entries for browsing without changing entry identity or media ownership.

## Durable model

Source-provided grouping uses an optional `Entry.groupID` scoped by `sourceID`. The same group string in two Sources therefore produces two independent groups. User stacks are ordered catalog records with a stable ID, name, ordered concrete entry IDs, and an optional remembered representative. A Library entry can belong to at most one user stack; collections remain separate ordered lists of concrete scene IDs.

Every child remains an ordinary Library entry with its own favorite, recency, metadata, availability and playable media reference. Removing a stack never removes media or entries. Removing entries prunes stack membership, clears a removed representative, and removes a stack when fewer than two members survive.

## SQLite schema v3

The existing `sqlite-v2` backend selector remains the backend-family marker. The selected database schema advances from v2 to v3 by adding `entries.group_id`, `user_stacks`, and `user_stack_items` in one `BEGIN IMMEDIATE` migration. `catalog_meta.schema_version` and `PRAGMA user_version` advance together. An older Idlesse build still recognizes that SQLite is authoritative and then fails closed on schema 3 instead of falling back to the historical JSON snapshot.

Stack writes retain the Library's cross-process file lock and SQLite transaction contract. Stale writers merge stack name, representative, ordered membership, and stack ordering independently; a deletion by another writer wins. SQLite applies row/relationship deltas and verifies integrity plus a semantic round trip before commit.

## Browsing projection

User stacks take presentation priority over Source groups. Source groups are derived from `(sourceID, groupID)` and never rewrite child entries. A stack exposes one representative for the gallery; a remembered user representative is used when available, while a search can temporarily choose the best matching child. Search matches title, series, character, variant, tags, and provenance values. Flat browsing remains a lossless projection over the same entries.

This phase intentionally leaves controller/grid UI untouched. The durable stack model and pure projection/search layer are covered first; UI can consume those APIs in a later slice without changing persistence semantics.
