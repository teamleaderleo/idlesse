import AppKit

extension SceneLibraryController {
    func setup() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let toolbar = setupBrowserControls()
        let right = setupDetailControls()
        installLibraryLayout(root: root, toolbar: toolbar, right: right)
        DispatchQueue.main.async { [weak self] in self?.updateThumbnailDemand() }
    }
}

extension SceneLibraryController {
    func setupDetailControls() -> NSStackView {
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
        poster.layer?.cornerRadius = 10
        poster.layer?.masksToBounds = true
        poster.setAccessibilityLabel("Selected wallpaper preview")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)

        favorite.target = self
        favorite.action = #selector(toggleFavorite)
        favorite.isBordered = false
        favorite.setAccessibilityLabel("Favorite wallpaper")
        apply.target = self
        apply.action = #selector(useScene)
        edit.target = self
        edit.action = #selector(editScene)
        for button in [apply, edit] { button.bezelStyle = .rounded }
        apply.bezelColor = .controlAccentColor
        apply.contentTintColor = .white

        more.addItems(withTitles: ["More…", "Show in Finder", "Details…", "Refresh Preview",
                                   "Make a Copy in Studio", "Remove Library Reference…"])
        more.menu?.autoenablesItems = false
        more.target = self
        more.action = #selector(moreAction)

        let heading = NSStackView(views: [titleLabel, NSView(), favorite])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        let primary = NSStackView(views: [apply, edit, more])
        primary.spacing = 10
        let right = NSStackView(views: [poster, heading, detail, primary])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        return right
    }
}

extension SceneLibraryController {
    func installLibraryLayout(root: NSView, toolbar: NSStackView, right: NSStackView) {
        for child in [listScroll, galleryScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            browserContainer.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: browserContainer.topAnchor),
                child.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor)
            ])
        }
        listScroll.isHidden = true

        for view in [sidebarScroll, toolbar, browserContainer, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        poster.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            sidebarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            sidebarScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 184),

            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: 18),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            browserContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            browserContainer.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: 18),
            browserContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            right.topAnchor.constraint(equalTo: browserContainer.topAnchor),
            right.leadingAnchor.constraint(equalTo: browserContainer.trailingAnchor, constant: 20),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            right.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
            right.widthAnchor.constraint(equalToConstant: 340).withPriority(.defaultHigh),

            poster.widthAnchor.constraint(equalTo: right.widthAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 9.0 / 16.0),
            right.arrangedSubviews[1].widthAnchor.constraint(equalTo: right.widthAnchor),
            detail.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
