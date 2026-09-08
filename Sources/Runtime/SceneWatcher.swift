import Foundation
import Darwin

/// Event-driven observation of the package, metadata, and referenced assets.
/// Parent directories catch atomic-save replacements. No polling or recursive scan.
final class SceneWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let urls: [URL]
    private let onChange: () -> Void
    init(package: URL, assets: [URL], onChange: @escaping () -> Void) {
        urls = Array(Set([package, package.deletingLastPathComponent(),
                          package.appendingPathComponent("manifest.json"),
                          package.appendingPathComponent("scene.json")] + assets + assets.map { $0.deletingLastPathComponent() }))
        self.onChange = onChange
        arm()
    }
    private func arm() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for url in urls {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in self?.changed() }
            sources.append(source)
            source.resume()
        }
    }
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.arm()
            self.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    deinit {
        pending?.cancel()
        sources.forEach { $0.cancel() }
    }
}
