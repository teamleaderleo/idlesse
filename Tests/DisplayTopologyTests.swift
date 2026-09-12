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
        // Simulate the same monitor reconnecting under UUID B with a slightly
        // different EDID millimetre report. Metadata matching must bridge the
        // changed canonical string and reject any ambiguous peer instead.
        let newIdentity = DisplayIdentity(
            colorSyncUUID: "SESSION-UUID-B", vendorID: 1552, modelID: 41032, serialNumber: 777,
            builtIn: false, physicalWidthMM: 600, physicalHeightMM: 336, name: "Desk Display")
        precondition(oldIdentity.durableKey != newIdentity.durableKey)

        let assignments = DisplayAssignmentStore(defaults: defaults, prefix: "displayReconnect")
        let identities = DisplayIdentityStore(defaults: defaults, prefix: "displayReconnect")
        let bookmark = Data([0x49, 0x44, 0x4c, 0x45])

        // Old #52-style session UUID has the bookmark before #31 observes it.
        defaults.set(bookmark, forKey: assignments.stableKey("SESSION-UUID-A"))
        precondition(assignments.reconcile(
            identityKey: oldIdentity.durableKey,
            persistentID: "SESSION-UUID-A",
            legacyDisplayID: 11) == bookmark)
        identities.remember(oldIdentity, assignmentKey: oldIdentity.durableKey)

        let previous = identities.previousAssignmentKey(
            for: newIdentity, proposedKey: newIdentity.durableKey)
        precondition(previous == oldIdentity.durableKey,
                     "Persisted identity metadata should uniquely match UUID A to UUID B")
        precondition(assignments.reconcile(
            identityKey: newIdentity.durableKey,
            previousIdentityKey: previous,
            persistentID: "SESSION-UUID-B",
            legacyDisplayID: 22) == bookmark)
        precondition(assignments.bookmarkData(
            persistentID: "SESSION-UUID-B", legacyDisplayID: 22) == bookmark,
            "Reconnect should seed the new #52 session key from the matched identity")
    }
}
