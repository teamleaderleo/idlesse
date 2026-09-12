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
