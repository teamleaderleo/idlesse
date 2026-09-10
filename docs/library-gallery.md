# Library gallery browsing

Library 2 keeps its existing JSON catalog, Sources, collections, schedules, individual
imports, and scene format. This pass changes Library presentation and thumbnail demand;
it does not introduce another catalog or animation format.

## Browser

Library opens in Gallery mode with a native AppKit source-list sidebar. Destinations are
All Wallpapers, Favorites, Included, Imported, every saved Library 2 Source, and every
Collection. Source rows use the stable Source IDs already stored by Library 2; selecting
a Source filters its source-backed entries without resolving every descendant.

The main browser is an `NSCollectionView` flow layout with reusable 16:9 artwork cards,
a restrained title row, a system-accent selection ring, and a favorite marker. The
Gallery/List segmented control preserves the compact `NSTableView` browser. Both modes
share the existing selected-item detail column and its composed 1024 × 576 still.
Selection is stored as a scene ID and follows that ID through search, sorting, sidebar
changes, collection reloads, and Gallery/List switches while the item remains in the
result. Collection views build one membership `Set` and rank dictionary per reload so
filtering and playback-order sorting stay linear/log-linear as catalogs grow.

Keyboard behavior is native and explicit: arrows move gallery selection, Return sets the
selected wallpaper, Space opens a transient larger still using the already-prepared detail
image, and Command-F focuses search. Delete and Forward Delete perform no Library removal.
Removal stays behind More → Remove Library Reference… (or Sources… → Remove Source…) with
copy stating that media in the granted folder stays untouched.

## Thumbnail demand and cancellation

Gallery cards are still images. They contain no live scene renderer and never play video.
Gallery demand consists of visible collection-view indexes plus at most 8 indexes before
and 8 after the visible span. List demand consists of visible rows plus at most 6 rows on
each side. Leaving the demand set cancels queued work immediately; an active
`AVAssetImageGenerator` receives `cancelAllCGImageGeneration()`. A synchronous ImageIO
thumbnail decode can finish its current scaled call after cancellation, and its result is
discarded.

There is exactly one ImageIO/raw-video thumbnail operation active at a time. Source access
and bookmark resolution occur inside that bounded worker. For Library 2 Source entries,
`SceneLibraryStore.Access` stays alive for the read, and `relativePosterPath` is preferred
through `accessPoster(_:)`. This keeps cloud-backed descendants untouched until a card
enters the visible/near-visible demand band, the item is selected, or the user invokes an
action that needs its file.

Thumbnail source order is:

1. Library 2 explicit poster path, when present.
2. Package `preview.jpg` or an existing adjacent JPEG sidecar.
3. ImageIO downsample for still media.
4. One first-frame `AVAssetImageGenerator` request for raw video.
5. For a package with no poster/sidecar, one on-demand composed still through the existing
   scene renderer.

ImageIO uses `CGImageSourceCreateThumbnailAtIndex` with a 384-pixel maximum dimension.
Raw-video generation is capped at 384 × 216 with preferred-track transform. Package
fallback composition renders at exactly 384 × 216 and has one active composition at a
time, with async cancellation checkpoints and renderer resource release after the frame.
The package compositor and the single ImageIO/raw-video operation can briefly overlap;
each remains independently bounded by the existing scene/video budgets.

## Memory budget

The shared Gallery/List thumbnail LRU accounts decoded pixels as
`width × height × 4`, evicts before crossing **16 MiB**, and also caps entries at **96**.
A full 384 × 216 card costs 331,776 bytes, so the pixel budget retains at most about 50
full-size cards before eviction. Framework object overhead and transient decoder working
buffers sit outside this raw-pixel accounting.

The selected-detail LRU remains four 1024 × 576 posters, exactly **9 MiB** of raw pixels.
Together, retained Library thumbnail pixels plus retained detail-poster pixels have an
explicit **25 MiB raw-pixel ceiling**. The Space preview reuses the selected poster image
and adds no cache entry. Closing Library cancels pending thumbnail/detail work and clears
both image caches. There is no disk thumbnail cache and no source-media duplication.

## Catalog scale and limitations

Library 2 keeps its existing limits: up to 4,096 source-backed entries total, 128
individual imports, 32 Sources, 256 favorites/recents, and 32 Collections with up to 256
scene references each, subject to the existing encoded-index byte limit. Gallery scale is
therefore driven primarily by Source catalogs; this pass does not loosen persistence
bounds merely to make the UI look larger.

The offscreen Library smoke covers Gallery/List selection persistence, arrow-navigation
math, the visible-band demand bound against a 1,000-item logical catalog, a 300-entry
Source-backed catalog, Source sidebar routing, existing collections/schedules, built-in
draft routing, and composed poster correctness. Live scrolling, VoiceOver focus order,
cloud-provider downloads, and macOS material appearance still require live macOS
validation.

Raw-video fallback cards use time zero while the selected composed poster uses the scene
preview time. Package fallback cards can arrive later than explicit posters and stills
because they run the real compositor once. Reopening Library regenerates cards because
the thumbnail cache is memory-only.
