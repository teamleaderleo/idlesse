import AppKit

typealias LibraryItem = SceneLibraryController.Item

protocol LibraryThumbnailRequest: AnyObject {
    func cancel()
}

/// A small admission gate in front of the existing thumbnail loader. Displayed
/// cells can cancel queued delivery as they leave the viewport, while decode
/// hand-off remains bounded during rapid scrolling.
private final class LibraryThumbnailBroker {
    private final class Request: LibraryThumbnailRequest {
        let id = UUID()
        let item: LibraryItem
        var completion: ((NSImage) -> Void)?
        var started = false
        var finished = false
        var cancelled = false
        weak var broker: LibraryThumbnailBroker?

        init(item: LibraryItem, completion: @escaping (NSImage) -> Void,
             broker: LibraryThumbnailBroker) {
            self.item = item
            self.completion = completion
            self.broker = broker
        }

        func cancel() {
            guard !cancelled, !finished else { return }
            cancelled = true
            completion = nil
            broker?.cancel(self)
        }
    }

    var loader: ((LibraryItem, @escaping (NSImage) -> Void) -> Void)? {
        didSet { pump() }
    }

    private let maxActive = 4
    private var queued: [Request] = []
    private var active: [UUID: Request] = [:]
    private(set) var cancellationCount = 0
    private(set) var startedCount = 0

    func request(_ item: LibraryItem, completion: @escaping (NSImage) -> Void) -> LibraryThumbnailRequest? {
        guard loader != nil else { return nil }
        let request = Request(item: item, completion: completion, broker: self)
        queued.append(request)
        pump()
        return request
    }

    func cancelAll() {
        for request in queued where !request.cancelled && !request.finished {
            cancellationCount += 1
            request.cancelled = true
            request.completion = nil
        }
        queued.removeAll()
        for request in active.values where !request.cancelled && !request.finished {
            cancellationCount += 1
            request.cancelled = true
            request.completion = nil
        }
        // ImageIO/AVAsset synchronous decode has no reliable interruption point
        // once begun. At most four such calls may finish; stale UI callbacks are
        // discarded and the controller's existing bounded cache owns retention.
    }

    private func cancel(_ request: Request) {
        cancellationCount += 1
        if !request.started {
            queued.removeAll { $0.id == request.id }
            pump()
        }
    }

    private func pump() {
        guard let loader else { return }
        queued.removeAll { $0.cancelled }
        while active.count < maxActive, !queued.isEmpty {
            let request = queued.removeFirst()
            guard !request.cancelled else { continue }
            request.started = true
            startedCount += 1
            active[request.id] = request
            loader(request.item) { [weak self, weak request] image in
                guard let self, let request, self.active[request.id] != nil else { return }
                let completion = request.cancelled ? nil : request.completion
                self.active.removeValue(forKey: request.id)
                request.finished = true
                request.completion = nil
                completion?(image)
                self.pump()
            }
            // The existing loader reports successful images only. This lease
            // releases the admission slot after a miss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak request] in
                guard let self, let request, self.active[request.id] != nil else { return }
                self.active.removeValue(forKey: request.id)
                request.finished = true
                request.completion = nil
                self.pump()
            }
        }
    }
}

/// Native virtualized Library gallery. NSCollectionView owns item lifetime and
/// reuse, so large Source catalogs materialize only AppKit's displayed working set.
final class LibraryGridView: NSCollectionView, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout {

    var onSelect: ((LibraryItem) -> Void)?
    var onDoubleAction: ((LibraryItem) -> Void)?
    var onRequestThumbnail: ((LibraryItem, @escaping (NSImage) -> Void) -> Void)? {
        didSet { thumbnailBroker.loader = onRequestThumbnail }
    }

    private static let cardIdentifier = NSUserInterfaceItemIdentifier("LibraryCard")
    private static let padding: CGFloat = 18
    private static let spacing: CGFloat = 16
    private static let minCardWidth: CGFloat = 200

    private var items: [LibraryItem] = []
    private var selectedID: String?
    private var suppressSelectionCallback = false
    private let thumbnailBroker = LibraryThumbnailBroker()
    private var updateGeneration = 0
    private var selectionGeneration = 0
    private var materializationRequestCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .vertical
        flow.sectionInset = NSEdgeInsets(top: Self.padding, left: Self.padding,
                                         bottom: Self.padding, right: Self.padding)
        flow.minimumInteritemSpacing = Self.spacing
        flow.minimumLineSpacing = Self.spacing
        collectionViewLayout = flow
        dataSource = self
        delegate = self
        isSelectable = true
        allowsMultipleSelection = false
        allowsEmptySelection = true
        backgroundColors = [.clear]
        register(LibraryCardItem.self, forItemWithIdentifier: Self.cardIdentifier)
        setAccessibilityLabel("Wallpapers grid")
        setAccessibilityHelp("Use the arrow keys to move between wallpapers. Press Return to set the selected wallpaper.")
    }

    func update(items newItems: [LibraryItem], selectedID: String?) {
        let anchor = items.isEmpty ? nil : scrollAnchor()
        let oldSignature = items.map {
            [$0.id, $0.title, $0.entry?.mediaType ?? "", $0.entry?.relativeMediaPath ?? ""].joined(separator: "\u{0}")
        }
        let newSignature = newItems.map {
            [$0.id, $0.title, $0.entry?.mediaType ?? "", $0.entry?.relativeMediaPath ?? ""].joined(separator: "\u{0}")
        }
        let changed = oldSignature != newSignature
        items = newItems
        self.selectedID = selectedID
        updateGeneration &+= 1
        let generation = updateGeneration

        if changed {
            thumbnailBroker.cancelAll()
            reloadData()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.updateGeneration == generation else { return }
                self.applySelection(id: selectedID)
                guard self.enclosingScrollView?.isHidden == false else { return }
                self.restore(anchor: anchor)
                self.revealSelectionIfNeeded(id: selectedID)
            }
            return
        }

        applySelection(id: selectedID)
        guard enclosingScrollView?.isHidden == false else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateGeneration == generation else { return }
            self.revealSelectionIfNeeded(id: selectedID)
        }
    }

    func select(id: String?, scrollIfNeeded: Bool? = nil) {
        selectedID = id
        selectionGeneration &+= 1
        let generation = selectionGeneration
        applySelection(id: id)
        let shouldScroll = scrollIfNeeded ?? (enclosingScrollView?.isHidden == false)
        guard shouldScroll else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionGeneration == generation else { return }
            self.revealSelectionIfNeeded(id: id)
        }
    }

    private func applySelection(id: String?) {
        guard let id else {
            guard !selectionIndexPaths.isEmpty else { return }
            suppressSelectionCallback = true
            selectionIndexPaths = []
            suppressSelectionCallback = false
            return
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            guard !selectionIndexPaths.isEmpty else { return }
            suppressSelectionCallback = true
            selectionIndexPaths = []
            suppressSelectionCallback = false
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        guard selectionIndexPaths != Set([indexPath]) else { return }
        suppressSelectionCallback = true
        selectionIndexPaths = Set([indexPath])
        suppressSelectionCallback = false
    }

    /// Hit-tests only the collection view's materialized geometry so the existing
    /// hover-peek monitor remains immediate and reliable when the pointer stops.
    func item(at point: NSPoint) -> LibraryItem? {
        guard let indexPath = indexPathForItem(at: point), items.indices.contains(indexPath.item) else {
            return nil
        }
        return items[indexPath.item]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        guard event.clickCount == 2, let indexPath, items.indices.contains(indexPath.item) else { return }
        onDoubleAction?(items[indexPath.item])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let indexPath = selectionIndexPaths.first, items.indices.contains(indexPath.item) {
                onDoubleAction?(items[indexPath.item])
                return
            }
        }
        super.keyDown(with: event)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard items.indices.contains(indexPath.item) else { return NSCollectionViewItem() }
        materializationRequestCount += 1
        guard let card = makeItem(withIdentifier: Self.cardIdentifier, for: indexPath) as? LibraryCardItem else {
            return NSCollectionViewItem()
        }
        let item = items[indexPath.item]
        let request = thumbnailBroker.request(item) { [weak card] image in
            guard card?.representedID == item.id else { return }
            card?.thumbnailView.image = image
        }
        card.configure(item: item, thumbnailRequest: request)
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !suppressSelectionCallback, let indexPath = indexPaths.first,
              items.indices.contains(indexPath.item) else { return }
        let item = items[indexPath.item]
        selectedID = item.id
        selectionGeneration &+= 1
        onSelect?(item)
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? LibraryCardItem)?.cancelThumbnail()
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        let viewport = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let width = max(300, viewport > 0 ? viewport : 800)
        let available = width - Self.padding * 2
        let columns = max(1, Int((available + Self.spacing) / (Self.minCardWidth + Self.spacing)))
        let cardWidth = floor((available - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
        return NSSize(width: cardWidth, height: cardWidth * 9.0 / 16.0 + 44)
    }

    private func revealSelectionIfNeeded(id: String?) {
        guard selectedID == id, let id,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        if let frame = collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame,
           frame.intersects(visibleRect) {
            return
        }
        scrollToItems(at: Set([indexPath]), scrollPosition: .nearestHorizontalEdge)
    }

    private func scrollAnchor() -> (id: String, offset: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView else { return nil }
        let candidates = indexPathsForVisibleItems().compactMap { indexPath -> (IndexPath, NSRect)? in
            guard items.indices.contains(indexPath.item),
                  let frame = collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.intersects(clip.bounds) else { return nil }
            return (indexPath, frame)
        }
        guard let nearest = candidates.min(by: {
            abs($0.1.minY - clip.bounds.minY) < abs($1.1.minY - clip.bounds.minY)
        }) else { return nil }
        return (items[nearest.0.item].id, clip.bounds.minY - nearest.1.minY)
    }

    private func restore(anchor: (id: String, offset: CGFloat)?) {
        guard let anchor, let clip = enclosingScrollView?.contentView,
              let index = items.firstIndex(where: { $0.id == anchor.id }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        scrollToItems(at: Set([indexPath]), scrollPosition: .top)
        guard let frame = collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let maxY = max(0, bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, frame.minY + anchor.offset), maxY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    var materializedItemCountForTesting: Int { materializationRequestCount }
    var totalItemCountForTesting: Int { items.count }
    var thumbnailRequestsStartedForTesting: Int { thumbnailBroker.startedCount }
    var thumbnailCancellationsForTesting: Int { thumbnailBroker.cancellationCount }
}

final class LibraryCardItem: NSCollectionViewItem {
    let thumbnailView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var thumbnailRequest: LibraryThumbnailRequest?
    fileprivate var representedID: String?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor, multiplier: 9.0 / 16.0),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            badgeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
        ])
        updateBorder()
    }

    override var isSelected: Bool {
        didSet { updateBorder() }
    }

    func configure(item: LibraryItem, thumbnailRequest: LibraryThumbnailRequest?) {
        cancelThumbnail()
        representedID = item.id
        self.thumbnailRequest = thumbnailRequest
        thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Wallpaper preview")
        titleLabel.stringValue = item.title
        let mediaPath = item.entry?.relativeMediaPath?.lowercased() ?? ""
        if mediaPath.hasSuffix(".mp4") || mediaPath.hasSuffix(".mov") || item.entry?.mediaType == "video" {
            badgeLabel.stringValue = "VIDEO"
        } else if item.builtin != nil || mediaPath.hasSuffix(".idlesse") || item.entry?.mediaType == "scene" {
            badgeLabel.stringValue = "INTERACTIVE SCENE"
        } else {
            badgeLabel.stringValue = "IMAGE"
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(item.title)
        view.setAccessibilityHelp("Double-click or press Return to set this wallpaper.")
        updateBorder()
    }

    func cancelThumbnail() {
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        representedID = nil
        thumbnailView.image = nil
        titleLabel.stringValue = ""
        badgeLabel.stringValue = ""
    }

    private func updateBorder() {
        guard isViewLoaded else { return }
        if isSelected {
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.layer?.borderWidth = 2.5
        } else {
            view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            view.layer?.borderWidth = 1
        }
    }
}
