import Foundation

private struct DisplayPlanCacheKey: Hashable {
    var owner: ObjectIdentifier
    var request: Int
    var topologySignature: String
    var mode: DisplayAssignmentMode
}

/// Small request-scoped cache shared by live-surface creation and system-backdrop
/// rendering. It holds immutable resolved values only; it never retains a
/// WallpaperController. Assignment-changing rebuilds explicitly invalidate the
/// current request before resolving a fresh plan.
private final class DisplayPlanCache {
    static let shared = DisplayPlanCache()
    private static let maxEntries = 16

    private let lock = NSLock()
    private var order: [DisplayPlanCacheKey] = []
    private var values: [DisplayPlanCacheKey: ResolvedWallpaperAssignmentPlan] = [:]

    func value(for key: DisplayPlanCacheKey,
               create: () -> ResolvedWallpaperAssignmentPlan) -> ResolvedWallpaperAssignmentPlan {
        lock.lock()
        if let cached = values[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = create()

        lock.lock()
        values[key] = resolved
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.maxEntries {
            values.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return resolved
    }

    func invalidate(owner: ObjectIdentifier, request: Int) {
        lock.lock()
        let stale = order.filter { $0.owner == owner && $0.request == request }
        for key in stale { values.removeValue(forKey: key) }
        order.removeAll { $0.owner == owner && $0.request == request }
        lock.unlock()
    }
}

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

extension WallpaperController {
    /// Resolve the currently adopted selection.
    func resolvedDisplayAssignmentPlan(topology: DisplayTopology = .current()) -> ResolvedWallpaperAssignmentPlan {
        resolvedDisplayAssignmentPlan(
            topology: topology,
            baseURL: selectedURL,
            desktopSpan: desktopSpanActive)
    }

    /// Resolve a candidate selection before `selectedURL`/`playable` are adopted.
    /// The same value can therefore drive live surfaces and matching system
    /// backdrop stills for one transaction.
    func resolvedDisplayAssignmentPlan(topology: DisplayTopology,
                                       baseURL: URL?,
                                       desktopSpan: Bool) -> ResolvedWallpaperAssignmentPlan {
        let mode: DisplayAssignmentMode = desktopSpan
            ? .desktopSpan
            : (sameWallpaperOnAllDisplays ? .sameOnAll : .perDisplay)
        let assignments = topology.displays.map { display -> ResolvedDisplayAssignment in
            let master = topology.master(for: display)
            let source: URL?
            let explicit: Bool
            switch mode {
            case .desktopSpan, .sameOnAll:
                source = baseURL
                explicit = false
            case .perDisplay:
                let override = explicitDisplayURL(for: master.liveID)
                source = override ?? baseURL
                explicit = override != nil
            }
            return ResolvedDisplayAssignment(
                persistentKey: topology.persistentKey(for: master),
                liveID: display.liveID,
                sourceURL: source,
                explicit: explicit,
                mirroredFrom: display.mirrorMasterID)
        }
        return ResolvedWallpaperAssignmentPlan(mode: mode, topology: topology, assignments: assignments)
    }

    /// Capture Same / Per Display / Desktop Span as the durable Ambient
    /// Arrangement Default. Duplicate mirror assignments collapse to one durable
    /// key so reconnects keep the user's independent-display intent.
    func persistedDisplayAssignmentPlan(topology: DisplayTopology = .current()) -> PersistedWallpaperAssignmentPlan {
        let resolved = resolvedDisplayAssignmentPlan(topology: topology)
        var seen: Set<String> = []
        let assignments: [PersistedWallpaperAssignmentPlan.Assignment] = resolved.assignments.compactMap { assignment in
            guard assignment.explicit, !seen.contains(assignment.persistentKey),
                  let url = assignment.sourceURL,
                  let data = Self.ambientBookmark(for: url) else { return nil }
            seen.insert(assignment.persistentKey)
            return .init(persistentKey: assignment.persistentKey, bookmark: data, explicit: true)
        }
        return PersistedWallpaperAssignmentPlan(
            mode: resolved.mode,
            topologySignature: topology.signature,
            baseBookmark: selectedURL.flatMap(Self.ambientBookmark),
            assignments: Array(assignments.prefix(PersistedWallpaperAssignmentPlan.maxAssignments)))
    }

    /// Restore persisted assignment intent through #52's durable assignment store.
    /// The current topology decides which remembered displays can be applied; an
    /// absent display keeps its saved assignment in the Ambient snapshot for a
    /// later reconnect.
    func applyPersistedDisplayAssignmentPlan(_ plan: PersistedWallpaperAssignmentPlan,
                                             topology: DisplayTopology = .current()) {
        guard plan.isValid else { return }
        reconcileDurableDisplayAssignments(topology: topology)
        let store = DisplayAssignmentStore(defaults: resumeDefaults,
                                           prefix: DisplayAssignmentStore.wallpaperPrefix)
        let byKey = Dictionary(uniqueKeysWithValues: plan.assignments.map { ($0.persistentKey, $0) })
        for display in topology.independentDisplays {
            let key = topology.persistentKey(for: display)
            let persistentID = Self.persistentDisplayIdentifier(display.liveID)
            if plan.mode == .perDisplay, let saved = byKey[key], saved.explicit {
                store.setBookmarkData(saved.bookmark, persistentID: persistentID)
                _ = store.reconcile(identityKey: key,
                                    persistentID: persistentID,
                                    legacyDisplayID: display.liveID)
            } else {
                store.clear(identityKey: key, persistentID: persistentID,
                            legacyDisplayID: display.liveID)
            }
        }
        // The setter performs the one rebuild/notification needed when the base
        // wallpaper is already the selected scene. Desktop Span is scene-owned;
        // selecting the captured base scene re-establishes that canvas mode.
        sameWallpaperOnAllDisplays = plan.mode != .perDisplay
    }

    private static func ambientBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope,
                               includingResourceValuesForKeys: nil, relativeTo: nil)) ??
            (try? url.bookmarkData(options: [],
                                   includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Immutable request snapshot shared by WallpaperController's two runtime
    /// consumers. `baseURL` is intentionally nil here: both consumers need the
    /// same explicit override decisions, while each already owns its default
    /// scene/source fallback.
    func sharedDisplayAssignmentPlan(request: Int, desktopSpan: Bool) -> ResolvedWallpaperAssignmentPlan {
        let topology = DisplayTopology.current()
        let mode: DisplayAssignmentMode = desktopSpan
            ? .desktopSpan
            : (sameWallpaperOnAllDisplays ? .sameOnAll : .perDisplay)
        let key = DisplayPlanCacheKey(
            owner: ObjectIdentifier(self),
            request: request,
            topologySignature: topology.signature,
            mode: mode)
        return DisplayPlanCache.shared.value(for: key) { [self] in
            resolvedDisplayAssignmentPlan(topology: topology, baseURL: nil, desktopSpan: desktopSpan)
        }
    }

    func invalidateSharedDisplayAssignmentPlan(request: Int) {
        DisplayPlanCache.shared.invalidate(owner: ObjectIdentifier(self), request: request)
    }

    /// Attach #52's UUID/direct-CG migration keys to persisted hardware identity.
    /// All reconnect matches are computed against the pre-refresh registry before
    /// any current identity is remembered, preventing loop-order bias for twins.
    func reconcileDurableDisplayAssignments(topology: DisplayTopology = .current()) {
        let assignmentStore = DisplayAssignmentStore(defaults: resumeDefaults,
                                                      prefix: DisplayAssignmentStore.wallpaperPrefix)
        let identityStore = DisplayIdentityStore(defaults: resumeDefaults,
                                                 prefix: DisplayAssignmentStore.wallpaperPrefix)
        let matches: [(DisplaySnapshot, String, String?)] = topology.displays.map { display in
            let currentKey = topology.persistentKey(for: display)
            let previous = identityStore.previousAssignmentKey(for: display.identity, proposedKey: currentKey)
            return (display, currentKey, previous)
        }

        for (display, currentKey, previousKey) in matches {
            assignmentStore.reconcile(
                identityKey: currentKey,
                previousIdentityKey: previousKey == currentKey ? nil : previousKey,
                persistentID: Self.persistentDisplayIdentifier(display.liveID),
                legacyDisplayID: display.liveID)
            identityStore.remember(display.identity, assignmentKey: currentKey)
        }
    }
}
