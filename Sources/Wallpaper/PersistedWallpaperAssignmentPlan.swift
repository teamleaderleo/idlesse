import Foundation

/// Durable, security-scoped snapshot of the user-controlled Arrangement Default.
/// Ambient Sets stores this instead of flattening the desktop to one wallpaper.
struct PersistedWallpaperAssignmentPlan: Codable, Equatable {
    struct Assignment: Codable, Equatable {
        var persistentKey: String
        var bookmark: Data
        var explicit: Bool
    }

    static let maxAssignments = 16
    static let maxBookmarkBytes = 16_384

    var mode: DisplayAssignmentMode
    var topologySignature: String
    var baseBookmark: Data?
    var assignments: [Assignment]

    var isValid: Bool {
        (baseBookmark?.count ?? 0) <= Self.maxBookmarkBytes &&
        assignments.count <= Self.maxAssignments &&
        assignments.allSatisfy {
            !$0.persistentKey.isEmpty && $0.persistentKey.utf8.count <= 1024 &&
            $0.bookmark.count <= Self.maxBookmarkBytes
        }
    }

    func baseURL() -> URL? {
        guard let baseBookmark else { return nil }
        return Self.resolveBookmark(baseBookmark)
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ??
            (try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                      relativeTo: nil, bookmarkDataIsStale: &stale))
    }
}
