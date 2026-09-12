import AppKit

typealias LibraryItem = SceneLibraryController.Item

final class LibraryGridView: NSView {
    var onSelect: ((LibraryItem) -> Void)?
    var onDoubleAction: ((LibraryItem) -> Void)?
    var onRequestThumbnail: ((LibraryItem, @escaping (NSImage) -> Void) -> Void)?

    private var items: [LibraryItem] = []
    private var selectedID: String?
    private var cardViews: [LibraryCardView] = []
    private var isRelayouting = false

    override var isFlipped: Bool { true }

    func update(items: [LibraryItem], selectedID: String?) {
        self.items = items
        self.selectedID = selectedID
        layoutCards()
    }

    func select(id: String?) {
        self.selectedID = id
        for card in cardViews {
            card.isSelected = card.item?.id == id
        }
    }

    /// Hit-tests a point in grid coordinates for hover-peek.
    func item(at point: NSPoint) -> LibraryItem? {
        for card in cardViews where card.frame.contains(point) {
            return card.item
        }
        return nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 1
        super.setFrameSize(newSize)
        if widthChanged && !isRelayouting {
            layoutCards()
        }
    }

    private func layoutCards() {
        guard !isRelayouting else { return }
        isRelayouting = true
        defer { isRelayouting = false }

        subviews.forEach { $0.removeFromSuperview() }
        cardViews.removeAll()

        let clipWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let width = max(300, clipWidth > 0 ? clipWidth : 800)
        let padding: CGFloat = 18
        let spacing: CGFloat = 16
        let minCardWidth: CGFloat = 200
        let availableWidth = width - (padding * 2)
        let columns = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
        let cardWidth = (availableWidth - (CGFloat(columns - 1) * spacing)) / CGFloat(columns)
        let cardHeight: CGFloat = cardWidth * 9.0 / 16.0 + 44

        var x = padding
        var y = padding
        var col = 0

        for item in items {
            let cardFrame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
            let card = LibraryCardView(frame: cardFrame, item: item)
            card.isSelected = item.id == selectedID
            card.onClick = { [weak self] item in
                self?.selectedID = item.id
                self?.select(id: item.id)
                self?.onSelect?(item)
            }
            card.onDoubleClick = { [weak self] item in
                self?.onDoubleAction?(item)
            }
            onRequestThumbnail?(item) { [weak card] image in
                card?.thumbnailView.image = image
            }
            addSubview(card)
            cardViews.append(card)

            col += 1
            if col >= columns {
                col = 0
                x = padding
                y += cardHeight + spacing
            } else {
                x += cardWidth + spacing
            }
        }

        let totalHeight = col == 0 ? y : (y + cardHeight + spacing)
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        super.setFrameSize(NSSize(width: width, height: max(totalHeight, visibleHeight)))
    }
}

final class LibraryCardView: NSView {
    let item: LibraryItem?
    var isSelected = false {
        didSet { updateBorder() }
    }
    var onClick: ((LibraryItem) -> Void)?
    var onDoubleClick: ((LibraryItem) -> Void)?

    let thumbnailView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    init(frame frameRect: NSRect, item: LibraryItem) {
        self.item = item
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let thumbHeight = frameRect.width * 9.0 / 16.0
        thumbnailView.frame = NSRect(x: 0, y: 0, width: frameRect.width, height: thumbHeight)
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Thumbnail")
        addSubview(thumbnailView)

        let labelY = thumbHeight + 5
        titleLabel.frame = NSRect(x: 8, y: labelY, width: frameRect.width - 16, height: 18)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.stringValue = SceneLibraryController.displayTitle(item.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        let badgeY = labelY + 18
        badgeLabel.frame = NSRect(x: 8, y: badgeY, width: frameRect.width - 16, height: 14)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        switch item.mediaKind {
        case .video: badgeLabel.stringValue = "VIDEO"
        case .scene: badgeLabel.stringValue = "INTERACTIVE SCENE"
        case .image, .other: badgeLabel.stringValue = "IMAGE"
        }
        addSubview(badgeLabel)

        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func updateBorder() {
        if isSelected {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2.5
        } else {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            layer?.borderWidth = 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        if event.clickCount == 2 {
            onDoubleClick?(item)
        } else {
            onClick?(item)
        }
    }
}
