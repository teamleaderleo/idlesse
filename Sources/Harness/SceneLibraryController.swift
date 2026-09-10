import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// Native artwork-first Library. Gallery cards are bounded still thumbnails; one selected
/// item retains the composed 1024 × 576 detail poster and its existing actions.
final class SceneLibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                    NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
                                    NSSearchFieldDelegate, NSWindowDelegate {
    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
    }
    struct OpenedItem {
        let url: URL
        let access: SceneLibraryStore.Access?
    }

    enum ViewMode { case gallery, list }
    enum SidebarKind: Equatable {
        case all, favorites, included, imported, heading, source(String), collection(String)
    }
    struct SidebarRow {
        let title: String
        let symbol: String?
        let kind: SidebarKind
    }

    let store: SceneLibraryStore
    let table = LibraryKeyTableView()
    let sidebar = LibraryKeyTableView()
    let collectionView = LibraryKeyCollectionView()
    let search = NSSearchField()
    // Kept as the single filter state so collection playback/schedule code and old tests
    // continue to use the same stable representedObject identifiers. It is not presented.
    let filter = NSPopUpButton()
    let sort = NSPopUpButton()
    let viewModeControl = NSSegmentedControl(labels: ["Gallery", "List"], trackingMode: .selectOne,
                                                      target: nil, action: nil)
    let collectionActions = NSPopUpButton(frame: .zero, pullsDown: true)
    let sourceActions = NSPopUpButton(frame: .zero, pullsDown: true)
    let listScroll = NSScrollView()
    let galleryScroll = NSScrollView()
    let sidebarScroll = NSScrollView()
    let browserContainer = NSView()
    let poster = NSImageView()
    let titleLabel = NSTextField(labelWithString: "Choose a wallpaper")
    let detail = NSTextField(wrappingLabelWithString: "")
    let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    let apply = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    let edit = NSButton(title: "Edit in Studio", target: nil, action: nil)
    let more = NSPopUpButton(frame: .zero, pullsDown: true)

    enum PosterRevision: Equatable, Sendable {
        case package(ScenePackageWriter.Revision)
        case file(Date?, Int?)
        static func read(_ source: URL) throws -> PosterRevision {
            var url = source
            url.removeAllCachedResourceValues()
            if url.pathExtension.lowercased() == "idlesse" { return .package(try ScenePackageWriter.revision(of: url)) }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return .file(values.contentModificationDate, values.fileSize)
        }
    }

    static let galleryThumbnailMaxPixel = 384
    static let galleryThumbnailPixelBudget = 16 * 1024 * 1024
    static let galleryThumbnailCacheEntryLimit = 96
    static let galleryThumbnailDecoderLimit = 1
    static let galleryPrefetchItems = 8
    static let listPrefetchRows = 6

    let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Idlesse.library.thumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = SceneLibraryController.galleryThumbnailDecoderLimit
        return queue
    }()
    lazy var thumbnails = ThumbnailCache(budget: Self.galleryThumbnailPixelBudget,
                                                 maxEntries: Self.galleryThumbnailCacheEntryLimit)
    var thumbnailOperations: [String: ThumbnailOperation] = [:]
    var wantedThumbnailIDs: Set<String> = []
    var composedThumbnailQueue: [String: Item] = [:]
    var composedThumbnailOrder: [String] = []
    var composedThumbnailTask: Task<Void, Never>?
    var composedThumbnailID: String?

    var cache: [String: (image: NSImage, note: String, revision: PosterRevision)] = [:]
    var cacheOrder: [String] = []
    var items: [Item] = []
    var sidebarRows: [SidebarRow] = []
    var selected: Item?
    var viewMode: ViewMode = .gallery
    var synchronizingSelection = false
    var synchronizingSidebar = false
    var task: Task<Void, Never>?
    var conversionTask: Task<Void, Never>?
    var importFailureHandler: (([String]) -> Void)?
    var activeUseAccess: [String: SceneLibraryStore.Access] = [:]
    var activeEditAccess: [String: SceneLibraryStore.Access] = [:]
    var activeSourceID: String?
    var generation = 0
    var quickPreviewPanel: NSPanel?
    var rotationTimer: Timer?
    var rotationCollectionID: String?
    var rotationQueue = SceneRotationQueue()
    var rotationShuffle = false
    var rotationMinutes = 30
    var scheduleTimer: Timer?
    var scheduleToken: String?
    var onUse: (URL) -> Void
    var onEdit: (URL, Bool) -> Void

    init(indexURL: URL? = nil, onUse: @escaping (URL) -> Void, onEdit: @escaping (URL, Bool) -> Void) throws {
        self.onUse = onUse
        self.onEdit = onEdit
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        store = try SceneLibraryStore(file: indexURL ?? support.appendingPathComponent("Idlesse/Library/index.json"))
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false))
        window?.title = "Idlesse Library"
        window?.minSize = NSSize(width: 980, height: 600)
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.center()
        setup()
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    weak var hostWindow: NSWindow?
    var presentationWindow: NSWindow? { hostWindow ?? window }
    var embedded = false


    deinit {
        NotificationCenter.default.removeObserver(self)
        conversionTask?.cancel()
        task?.cancel()
        thumbnailQueue.cancelAllOperations()
        composedThumbnailTask?.cancel()
        rotationTimer?.invalidate()
        scheduleTimer?.invalidate()
    }
}
