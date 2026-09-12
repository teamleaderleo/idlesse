import Foundation

struct DisplayAssignmentStore {
    static let wallpaperPrefix = "wallpaperResumeBookmark"

    let defaults: UserDefaults
    let prefix: String

    func stableKey(_ persistentID: String) -> String {
        "\(prefix).display.\(persistentID)"
    }

    func legacyKey(_ displayID: UInt32) -> String {
        "\(prefix).\(displayID)"
    }

    func identityKey(_ durableIdentity: String) -> String {
        "\(prefix).identity.\(durableIdentity)"
    }

    private func aliasKey(_ persistentID: String) -> String {
        "\(prefix).displayAlias.\(persistentID)"
    }

    /// Existing #52 runtime entry point. Once a visual-display reconciliation
    /// has linked this session UUID to a durable identity, reads and writes keep
    /// the identity copy in sync while retaining the UUID key for compatibility.
    func bookmarkData(persistentID: String, legacyDisplayID: UInt32) -> Data? {
        let key = stableKey(persistentID)
        if let data = defaults.data(forKey: key) {
            mirrorToIdentity(data, persistentID: persistentID)
            return data
        }
        if let durable = defaults.string(forKey: aliasKey(persistentID)),
           let data = defaults.data(forKey: identityKey(durable)) {
            defaults.set(data, forKey: key)
            return data
        }
        let legacy = legacyKey(legacyDisplayID)
        guard let data = defaults.data(forKey: legacy) else { return nil }
        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacy)
        mirrorToIdentity(data, persistentID: persistentID)
        return data
    }

    func setBookmarkData(_ data: Data, persistentID: String) {
        defaults.set(data, forKey: stableKey(persistentID))
        mirrorToIdentity(data, persistentID: persistentID)
    }

    func clear(persistentID: String, legacyDisplayID: UInt32) {
        defaults.removeObject(forKey: stableKey(persistentID))
        defaults.removeObject(forKey: legacyKey(legacyDisplayID))
        if let durable = defaults.string(forKey: aliasKey(persistentID)) {
            defaults.removeObject(forKey: identityKey(durable))
        }
        defaults.removeObject(forKey: aliasKey(persistentID))
    }

    /// Link the session's ColorSync/CG identifier to the richer hardware
    /// identity. This migrates direct-CG and #52 UUID persistence in place and
    /// also restores an assignment when macOS gives the same monitor a new live
    /// identifier after dock/reconnect.
    @discardableResult
    func reconcile(identityKey durableIdentity: String, persistentID: String,
                   legacyDisplayID: UInt32) -> Data? {
        let durableKey = identityKey(durableIdentity)
        let sessionKey = stableKey(persistentID)
        let oldKey = legacyKey(legacyDisplayID)
        let data = defaults.data(forKey: durableKey)
            ?? defaults.data(forKey: sessionKey)
            ?? defaults.data(forKey: oldKey)
        guard let data else {
            defaults.set(durableIdentity, forKey: aliasKey(persistentID))
            return nil
        }
        defaults.set(data, forKey: durableKey)
        defaults.set(data, forKey: sessionKey)
        defaults.set(durableIdentity, forKey: aliasKey(persistentID))
        defaults.removeObject(forKey: oldKey)
        return data
    }

    func clear(identityKey durableIdentity: String, persistentID: String, legacyDisplayID: UInt32) {
        defaults.removeObject(forKey: identityKey(durableIdentity))
        defaults.removeObject(forKey: stableKey(persistentID))
        defaults.removeObject(forKey: legacyKey(legacyDisplayID))
        defaults.removeObject(forKey: aliasKey(persistentID))
    }

    private func mirrorToIdentity(_ data: Data, persistentID: String) {
        guard let durable = defaults.string(forKey: aliasKey(persistentID)) else { return }
        defaults.set(data, forKey: identityKey(durable))
    }
}
