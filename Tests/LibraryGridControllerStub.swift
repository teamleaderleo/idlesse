import Foundation

final class SceneLibraryController {
    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
    }
}
