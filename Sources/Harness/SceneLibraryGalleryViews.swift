import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

final class LibraryKeyTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class LibraryKeyCollectionView: NSCollectionView {
    var keyHandler: ((NSEvent) -> Bool)?
    var doubleClickHandler: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { doubleClickHandler?() }
    }
}

final class LibraryGalleryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibraryGalleryItem")
    let artwork = NSImageView()
    let title = NSTextField(labelWithString: "")
    let star = NSImageView()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 10

        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        artwork.layer?.cornerRadius = 8
        artwork.layer?.masksToBounds = true
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.setAccessibilityElement(false)

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityElement(false)

        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        star.contentTintColor = .white
        star.wantsLayer = true
        star.layer?.shadowColor = NSColor.black.cgColor
        star.layer?.shadowOpacity = 0.55
        star.layer?.shadowRadius = 2
        star.translatesAutoresizingMaskIntoConstraints = false
        star.setAccessibilityElement(false)

        root.addSubview(artwork)
        root.addSubview(title)
        artwork.addSubview(star)
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: root.topAnchor, constant: 3),
            artwork.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 3),
            artwork.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
            artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor, multiplier: 9.0 / 16.0),
            title.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: 7),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            title.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -2),
            star.topAnchor.constraint(equalTo: artwork.topAnchor, constant: 8),
            star.trailingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: -8),
            star.widthAnchor.constraint(equalToConstant: 14),
            star.heightAnchor.constraint(equalToConstant: 14)
        ])
        view = root
        imageView = artwork
        textField = title
        updateSelection()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    func configure(title value: String, favorite: Bool, image: NSImage?) {
        loadViewIfNeeded()
        title.stringValue = value
        star.isHidden = !favorite
        artwork.image = image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        artwork.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(value + (favorite ? ", favorite" : ""))
        view.setAccessibilityHelp("Arrow keys move selection. Return sets this wallpaper. Space shows a larger still preview.")
    }

    func updateSelection() {
        guard isViewLoaded else { return }
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        view.layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor.clear).cgColor
    }
}
