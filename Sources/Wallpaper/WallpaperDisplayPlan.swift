import Foundation

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
