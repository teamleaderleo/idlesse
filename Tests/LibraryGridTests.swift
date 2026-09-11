import AppKit
import Darwin

@main struct LibraryGridTests {
    private static func synthetic(_ count: Int) -> [LibraryItem] {
        (0..<count).map { index in
            LibraryItem(id: "synthetic-\(index)", title: "Synthetic Wallpaper \(index)", builtin: nil, entry: nil)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("library-grid assertion failed: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func finish(_ callbacks: inout [(NSImage) -> Void]) {
        let image = NSImage(size: NSSize(width: 16, height: 9))
        let current = callbacks
        callbacks.removeAll()
        current.forEach { $0(image) }
    }

    static func main() {
        _ = NSApplication.shared
        let grid = LibraryGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        var requestedIDs: [String] = []
        var pending: [(NSImage) -> Void] = []
        grid.onRequestThumbnail = { item, completion in
            requestedIDs.append(item.id)
            pending.append(completion)
        }

        // A catalog refresh alone stays metadata-only: no card creation or
        // thumbnail hand-off simply because a Source contains many entries.
        grid.update(items: synthetic(1_000), selectedID: nil)
        require(grid.totalItemCountForTesting == 1_000, "Expected the 1,000-entry data source")
        require(grid.materializedItemCountForTesting == 0,
                "Loading 1,000 entries must not instantiate collection-view cards eagerly")
        require(requestedIDs.isEmpty,
                "Loading 1,000 entries must not request artwork eagerly")

        // Exercise the production card path for a viewport-sized working set.
        var cards: [(IndexPath, NSCollectionViewItem)] = []
        for index in 0..<24 {
            let path = IndexPath(item: index, section: 0)
            cards.append((path, grid.collectionView(grid, itemForRepresentedObjectAt: path)))
        }
        require(grid.materializedItemCountForTesting == 24,
                "Only requested collection-view items should be materialized")
        require(requestedIDs.count == 4 && grid.thumbnailRequestsStartedForTesting == 4,
                "Thumbnail decode hand-off must stay capped at four while work is in flight")

        let cancellationsBefore = grid.thumbnailCancellationsForTesting
        for (path, card) in cards {
            grid.collectionView(grid, didEndDisplaying: card, forRepresentedObjectAt: path)
        }
        require(grid.thumbnailCancellationsForTesting > cancellationsBefore,
                "Offscreen/reused cards must cancel thumbnail delivery")
        finish(&pending)

        let materializedBeforeLargeReload = grid.materializedItemCountForTesting
        let requestsBeforeLargeReload = requestedIDs.count
        grid.update(items: synthetic(4_000), selectedID: nil)
        require(grid.totalItemCountForTesting == 4_000, "Expected the 4,000-entry data source")
        require(grid.materializedItemCountForTesting == materializedBeforeLargeReload,
                "Loading 4,000 entries must not instantiate additional cards eagerly")
        require(requestedIDs.count == requestsBeforeLargeReload,
                "Loading 4,000 entries must not decode artwork merely because entries exist")

        var largeCards: [(IndexPath, NSCollectionViewItem)] = []
        for index in 2_500..<2_524 {
            let path = IndexPath(item: index, section: 0)
            largeCards.append((path, grid.collectionView(grid, itemForRepresentedObjectAt: path)))
        }
        require(grid.materializedItemCountForTesting - materializedBeforeLargeReload == 24,
                "The 4,000-entry catalog should still materialize only the requested working set")
        require(requestedIDs.count - requestsBeforeLargeReload == 4,
                "The 4,000-entry working set must keep decode hand-off bounded")

        for (path, card) in largeCards {
            grid.collectionView(grid, didEndDisplaying: card, forRepresentedObjectAt: path)
        }
        finish(&pending)

        print("Library grid virtualization checks passed: 1,000/4,000 catalog loads stay metadata-only; card and decode work stays working-set bounded")
    }
}
