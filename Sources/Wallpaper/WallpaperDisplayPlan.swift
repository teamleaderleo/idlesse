import Foundation

extension WallpaperController {
    /// Resolve display mode, mirror groups and effective Library sources in one
    /// value. Visual Displays and runtime assignment consumers can inspect the
    /// same result without rebuilding display-policy rules independently.
    func resolvedDisplayAssignmentPlan(topology: DisplayTopology = .current()) -> ResolvedWallpaperAssignmentPlan {
        let mode: DisplayAssignmentMode = desktopSpanActive
            ? .desktopSpan
            : (sameWallpaperOnAllDisplays ? .sameOnAll : .perDisplay)
        let assignments = topology.displays.map { display -> ResolvedDisplayAssignment in
            let master = topology.master(for: display)
            let source: URL?
            let explicit: Bool
            switch mode {
            case .desktopSpan, .sameOnAll:
                source = selectedURL
                explicit = false
            case .perDisplay:
                source = displayURL(for: master.liveID)
                explicit = explicitDisplayURL(for: master.liveID) != nil
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
