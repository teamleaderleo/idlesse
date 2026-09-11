# Library grid virtualization

Track B of issue #28 replaces the eager Library gallery with native `NSCollectionView` virtualization. The Library index and Source storage model stay unchanged.

## Runtime behavior

- `NSCollectionView` with `NSCollectionViewFlowLayout` owns card creation and reuse. Catalog size changes the data-source count while card objects stay tied to AppKit's displayed working set.
- Artwork requests start only when AppKit asks the data source for a `LibraryCardItem`. A broker admits at most four thumbnail/decode requests at once, so rapid scrolling cannot hand an unbounded queue to ImageIO or AVAsset.
- Reused or offscreen cards cancel their delivery lease. Pending requests disappear immediately. Decoder calls already handed off are bounded to four and may finish into the existing cache; stale UI callbacks are discarded. A timeout releases broker slots for files that produce no thumbnail callback.
- The controller's existing thumbnail cache remains the sole retained artwork cache, including its 64 MiB `totalCostLimit` and 64-image count limit. The grid keeps no second image cache.
- Large Sources therefore do not cause bookmark resolution, cloud-backed media reads, ImageIO decode, or video frame generation merely because their entries exist. Only cards AppKit actually materializes can reach the existing thumbnail loader.

## Interaction preservation

The grid keeps the existing responsive card sizing, List/Grid switch, filter/search ordering, favorites and collections because those continue to be owned by `SceneLibraryController`. Selection is mirrored through the existing callbacks. Reloads keep a surviving top-visible item pinned where possible, while a newly selected item is revealed when the grid is visible.

Double-click and Return/Enter both invoke Set Wallpaper. Native collection-view selection supplies arrow-key navigation, and each card exposes an accessibility label/help string. Hover hit-testing uses the collection view's materialized geometry, so the existing hover-peek path stays immediate while avoiding an all-catalog card scan.

## Scalability coverage

`Tests/LibraryGridTests.swift` compiles the production collection view and thumbnail broker against synthetic 1,000-entry and 4,000-entry catalogs. The test remains headless so it is deterministic on hosted macOS runners. It asserts that:

- replacing the catalog with 1,000 or 4,000 entries performs zero eager card materializations and zero artwork requests;
- asking the real collection-view data source for a 24-card working set creates exactly those 24 cards;
- thumbnail/decode hand-off stays capped at four while work is in flight;
- ending display for those cards cancels queued/offscreen delivery;
- the same bounded behavior holds for cards deep inside a 4,000-entry catalog.

The test is part of `./test.sh` as the `library-grid` binary. Library storage coverage remains in the existing `library` binary.