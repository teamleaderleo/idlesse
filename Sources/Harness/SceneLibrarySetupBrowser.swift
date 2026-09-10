import AppKit

extension SceneLibraryController {
    func setupBrowserControls() -> NSStackView {
        search.placeholderString = "Search wallpapers"
        search.delegate = self
        search.setAccessibilityLabel("Search wallpapers")

        filter.addItems(withTitles: ["All Wallpapers", "Included", "Imported", "Favorites"])
        filter.target = self
        filter.action = #selector(filterChanged)

        sort.addItems(withTitles: ["Name", "Recently Opened"])
        sort.target = self
        sort.action = #selector(filterChanged)
        sort.setAccessibilityLabel("Sort wallpapers")

        viewModeControl.selectedSegment = 0
        viewModeControl.target = self
        viewModeControl.action = #selector(changeViewMode)
        viewModeControl.setAccessibilityLabel("Library view")

        let add = NSButton(title: "Import…", target: self, action: #selector(addScenes))
        add.bezelStyle = .rounded
        add.setAccessibilityLabel("Import wallpapers")

        collectionActions.addItem(withTitle: "Collections…")
        collectionActions.target = self
        collectionActions.action = #selector(collectionAction)

        sourceActions.addItem(withTitle: "Sources…")
        sourceActions.target = self
        sourceActions.action = #selector(sourceAction)

        let toolbar = NSStackView(views: [search, sort, viewModeControl, collectionActions, sourceActions, add])
        toolbar.spacing = 10
        toolbar.alignment = .centerY

        let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LibrarySection"))
        sidebarColumn.width = 178
        sidebarColumn.resizingMask = .autoresizingMask
        sidebar.addTableColumn(sidebarColumn)
        sidebar.headerView = nil
        sidebar.rowHeight = 30
        sidebar.style = .sourceList
        sidebar.delegate = self
        sidebar.dataSource = self
        sidebar.setAccessibilityLabel("Library sections")
        sidebar.keyHandler = { [weak self] event in self?.handleCommonKey(event) ?? false }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Scene"))
        column.width = 360
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.style = .sourceList
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(doubleClickScene)
        table.setAccessibilityLabel("Wallpaper list")
        table.registerForDraggedTypes([.fileURL])
        table.keyHandler = { [weak self] event in
            guard let self else { return false }
            if self.handleCommonKey(event) { return true }
            if event.keyCode == 36 || event.keyCode == 76 { self.useScene(); return true }
            if event.keyCode == 49 { self.toggleQuickPreview(); return true }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.removalKeyNotice()
                return true
            }
            return false
        }

        let flow = NSCollectionViewFlowLayout()
        flow.minimumInteritemSpacing = 16
        flow.minimumLineSpacing = 18
        flow.sectionInset = NSEdgeInsets(top: 8, left: 6, bottom: 18, right: 6)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.register(LibraryGalleryItem.self,
                                forItemWithIdentifier: LibraryGalleryItem.reuseIdentifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setAccessibilityLabel("Wallpaper gallery")
        collectionView.keyHandler = { [weak self] event in self?.handleGalleryKey(event) ?? false }
        collectionView.doubleClickHandler = { [weak self] in self?.doubleClickGalleryItem() }

        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        galleryScroll.documentView = collectionView
        galleryScroll.hasVerticalScroller = true
        galleryScroll.drawsBackground = false
        listScroll.contentView.postsBoundsChangedNotifications = true
        galleryScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(browserDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: listScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(browserDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: galleryScroll.contentView)
        return toolbar
    }
}
