import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? sidebarRows.count : items.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === sidebar { return sidebarRows.indices.contains(row) && sidebarRows[row].kind != .heading }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar {
            guard sidebarRows.indices.contains(row) else { return nil }
            let value = sidebarRows[row]
            if value.kind == .heading {
                let label = NSTextField(labelWithString: value.title)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                let cell = NSTableCellView()
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                    label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)
                ])
                return cell
            }
            let label = NSTextField(labelWithString: value.title)
            label.lineBreakMode = .byTruncatingTail
            let image = value.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            let icon = NSImageView(image: image ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let cell = NSTableCellView()
            cell.textField = label
            cell.imageView = icon
            icon.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let text = NSTextField(labelWithString:
            (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)
        text.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        cell.textField = text
        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        thumbnail.image = thumbnails.latest(item.id) ??
            NSImage(systemSymbolName: "photo", accessibilityDescription: "Wallpaper preview")
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(thumbnail)
        cell.imageView = thumbnail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 80),
            thumbnail.heightAnchor.constraint(equalToConstant: 45),
            text.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        requestThumbnailIfWanted(item)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let changed = notification.object as? NSTableView else { return }
        if changed === sidebar {
            guard !synchronizingSidebar else { return }
            applySidebarSelection(sidebar.selectedRow)
            return
        }
        guard changed === table, !synchronizingSelection else { return }
        let item = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        select(item)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: LibraryGalleryItem.reuseIdentifier,
                                           for: indexPath) as! LibraryGalleryItem
        let item = items[indexPath.item]
        card.representedObject = item.id
        card.configure(title: item.title, favorite: store.catalog.favorites.contains(item.id),
                       image: thumbnails.latest(item.id))
        requestThumbnailIfWanted(item)
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !synchronizingSelection, let path = indexPaths.first, items.indices.contains(path.item) else { return }
        select(items[path.item])
    }

    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        let metrics = galleryMetrics(for: collectionView.bounds.width)
        return NSSize(width: metrics.width, height: floor(metrics.width * 9.0 / 16.0) + 31)
    }

    func galleryMetrics(for totalWidth: CGFloat) -> (columns: Int, width: CGFloat) {
        let spacing: CGFloat = 16
        let horizontalInsets: CGFloat = 12
        let content = max(1, totalWidth - horizontalInsets)
        let columns = max(1, Int(ceil((content + spacing) / (320 + spacing))))
        let width = max(1, floor((content - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
        return (columns, width)
    }

}
