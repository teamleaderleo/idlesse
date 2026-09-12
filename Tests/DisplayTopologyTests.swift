import AppKit

@main struct DisplayTopologyTests {
    static func main() {
        DisplayTopologySmoke.run()
        reconnectMigrationSmoke()
        print("display topology tests passed")
    }

    private static func reconnectMigrationSmoke() {
        let suite = "DisplayReconnectMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldIdentity = DisplayIdentity(
            colorSyncUUID: "SESSION-UUID-A", vendorID: 1552, modelID: 41032, serialNumber: 777,
            builtIn: false, physicalWidthMM: 598, physicalHeightMM: 336, name: "Desk Display")
        let newIdentity = DisplayIdentity(
            colorSyncUUID: "SESSION-UUID-B", vendorID: 1552, modelID: 41032, serialNumber: 777,
            builtIn: false, physicalWidthMM: 602, physicalHeightMM: 338, name: "Écran de bureau")
        precondition(oldIdentity.deviceKey == newIdentity.deviceKey,
                     "Serial-backed identity must survive UUID, size-report and localized-name churn")

        let assignments = DisplayAssignmentStore(defaults: defaults, prefix: "displayReconnect")
        let identities = DisplayIdentityStore(defaults: defaults, prefix: "displayReconnect")
        let bookmark = Data([0x49, 0x44, 0x4c, 0x45])

        // Existing #52 session UUID owns the bookmark before #31 observes it.
        defaults.set(bookmark, forKey: assignments.stableKey("SESSION-UUID-A"))
        precondition(assignments.reconcile(
            identityKey: oldIdentity.deviceKey,
            persistentID: "SESSION-UUID-A",
            legacyDisplayID: 11) == bookmark)
        identities.remember(oldIdentity, assignmentKey: oldIdentity.deviceKey)

        let previous = identities.previousAssignmentKey(
            for: newIdentity, proposedKey: newIdentity.deviceKey)
        precondition(previous == oldIdentity.deviceKey,
                     "Persisted hardware identity should resolve the reconnect deterministically")
        precondition(assignments.reconcile(
            identityKey: newIdentity.deviceKey,
            previousIdentityKey: previous == newIdentity.deviceKey ? nil : previous,
            persistentID: "SESSION-UUID-B",
            legacyDisplayID: 22) == bookmark)
        precondition(assignments.bookmarkData(
            persistentID: "SESSION-UUID-B", legacyDisplayID: 22) == bookmark,
            "Reconnect should seed the new #52 session key from durable device identity")
    }
}
