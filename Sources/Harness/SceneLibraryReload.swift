import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    @objc func filterChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    func reload(selecting id: String? = nil) {
        reloadSourceActions()
        if let activeSourceID, !store.catalog.sources.contains(where: { $0.id == activeSourceID }) { self.activeSourceID = nil }
        let previous = id ?? selected?.id
        let collectionID = filter.selectedItem?.representedObject as? String
        let previousFilter = min(filter.indexOfSelectedItem, 3)

        filter.removeAllItems()
        filter.addItems(withTitles: ["All Wallpapers", "Included", "Imported", "Favorites"])
        for collection in store.catalog.collections {
            filter.addItem(withTitle: "Collection: \(collection.name)")
            filter.lastItem?.representedObject = collection.id
        }
        if let collectionID,
           let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == collectionID }) {
            filter.selectItem(at: index)
        } else {
            filter.selectItem(at: max(0, previousFilter))
        }

        let activeCollection = store.catalog.collections.first {
            $0.id == (filter.selectedItem?.representedObject as? String)
        }
        let collectionMembers = activeCollection.map { Set($0.sceneIDs) }
        let collectionRank = activeCollection.map {
            Dictionary(uniqueKeysWithValues: $0.sceneIDs.enumerated().map { ($0.element, $0.offset) })
        }

        items = allItems().filter { item in
            let matches = search.stringValue.isEmpty ||
                item.title.localizedCaseInsensitiveContains(search.stringValue)
            if let activeSourceID { return matches && item.entry?.sourceID == activeSourceID }
            if let collectionMembers { return matches && collectionMembers.contains(item.id) }
            switch filter.indexOfSelectedItem {
            case 1: return matches && item.builtin != nil
            case 2: return matches && item.entry != nil
            case 3: return matches && store.catalog.favorites.contains(item.id)
            default: return matches
            }
        }.sorted {
            if let collectionRank {
                return (collectionRank[$0.id] ?? .max) < (collectionRank[$1.id] ?? .max)
            }
            if sort.indexOfSelectedItem == 1 {
                let a = store.catalog.recent[$0.id] ?? .distantPast
                let b = store.catalog.recent[$1.id] ?? .distantPast
                if a != b { return a > b }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        table.reloadData()
        collectionView.reloadData()
        rebuildSidebar()

        if let index = items.firstIndex(where: { $0.id == previous }) ?? (items.isEmpty ? nil : 0) {
            selected = items[index]
            synchronizeSelectionViews(index: index, reveal: true)
            preview()
        } else {
            selected = nil
            synchronizeSelectionViews(index: nil, reveal: false)
            preview()
        }
        DispatchQueue.main.async { [weak self] in
            self?.collectionView.collectionViewLayout?.invalidateLayout()
            self?.updateThumbnailDemand()
        }
    }

    func rebuildSidebar() {
        sidebarRows = [
            SidebarRow(title: "All Wallpapers", symbol: "photo.on.rectangle.angled", kind: .all),
            SidebarRow(title: "Favorites", symbol: "star", kind: .favorites),
            SidebarRow(title: "Included", symbol: "shippingbox", kind: .included),
            SidebarRow(title: "Imported", symbol: "tray.and.arrow.down", kind: .imported)
        ]
        if !store.catalog.sources.isEmpty {
            sidebarRows.append(SidebarRow(title: "SOURCES", symbol: nil, kind: .heading))
            sidebarRows.append(contentsOf: store.catalog.sources.map {
                SidebarRow(title: $0.name, symbol: "folder", kind: .source($0.id))
            })
        }
        sidebarRows.append(SidebarRow(title: "COLLECTIONS", symbol: nil, kind: .heading))
        sidebarRows.append(contentsOf: store.catalog.collections.map {
            SidebarRow(title: $0.name, symbol: "rectangle.stack", kind: .collection($0.id))
        })
        sidebar.reloadData()
        let kind = currentSidebarKind()
        if let row = sidebarRows.firstIndex(where: { $0.kind == kind }) {
            synchronizingSidebar = true
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            synchronizingSidebar = false
        }
    }

    func currentSidebarKind() -> SidebarKind {
        if let activeSourceID { return .source(activeSourceID) }
        if let id = filter.selectedItem?.representedObject as? String { return .collection(id) }
        switch filter.indexOfSelectedItem {
        case 1: return .included
        case 2: return .imported
        case 3: return .favorites
        default: return .all
        }
    }

    func applySidebarSelection(_ row: Int) {
        guard sidebarRows.indices.contains(row) else { return }
        switch sidebarRows[row].kind {
        case .all:
            activeSourceID = nil; filter.selectItem(at: 0)
        case .included:
            activeSourceID = nil; filter.selectItem(at: 1)
        case .imported:
            activeSourceID = nil; filter.selectItem(at: 2)
        case .favorites:
            activeSourceID = nil; filter.selectItem(at: 3)
        case .source(let id):
            activeSourceID = id; filter.selectItem(at: 2)
        case .collection(let id):
            activeSourceID = nil
            if let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
                filter.selectItem(at: index)
            }
        case .heading: return
        }
        reload()
    }

}
