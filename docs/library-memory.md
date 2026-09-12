# Library memory and Smart Collections

This #25 slice stays inside the Quarry catalog. Ratings and play counts are keyed by stable `Entry.id` in SQLite `item_state`; ordinary collections remain concrete ordered entry IDs.

Smart Collections are saved definitions, not copied membership. Each uses 1–8 predicates from a bounded vocabulary: favorite, minimum rating, minimum plays, unplayed, media type, series, character, tag, Source ID, and exact duplicate. Predicates combine with AND and members are recomputed from current catalog state. Sort choices are name, rating, recent use, or play count.

Weighted playback boosts ratings/favorites. Surprise playback favors less-played and less-recent entries while still allowing modest favorite/rating bias. Both accept a deterministic seed for tests. Repetition history belongs to Drift (#37), which stacks next.

Duplicate detection is conservative: individual imports already coalesce the same resolved file, while catalog duplicate groups require identical verified content digests. It never silently merges entries or user state.

A disk thumbnail cache is intentionally deferred: #35/#36 already bound live thumbnail work, and this slice has no repeated-browsing measurement showing disk caching would repay its invalidation and storage cost.

📚 Curator

## Library surface

The preview shows an explicit 1–5 star rating and local play count. Smart Collections are authored from one required and one optional readable condition, with name/rating/recent/play-count sorting. Collection playback offers Order, Shuffle, Weighted, and Surprise choices. Exact duplicate membership is visible in the preview and available as a Smart Collection condition; detection remains advisory and never merges entries.
