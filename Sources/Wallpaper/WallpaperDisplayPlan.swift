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

    /// Attach #52's session UUID/direct-CG migration keys to the richer display
    /// identity before resolving assignments. Reconnects can therefore recover
    /// an existing bookmark even when the live display handle changes.
    func reconcileDurableDisplayAssignments(topology: DisplayTopology = .current()) {
        let store = DisplayAssignmentStore(defaults: resumeDefaults,
                                           prefix: DisplayAssignmentStore.wallpaperPrefix)
        for display in topology.displays {
            store.reconcile(identityKey: topology.persistentKey(for: display),
                            persistentID: Self.persistentDisplayIdentifier(display.liveID),
                            legacyDisplayID: display.liveID)
        }
    }
}
