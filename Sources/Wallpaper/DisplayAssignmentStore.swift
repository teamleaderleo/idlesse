import Foundation

struct DisplayAssignmentStore {
    let defaults: UserDefaults
    let prefix: String

    func stableKey(_ persistentID: String) -> String {
        "\(prefix).display.\(persistentID)"
    }

    func legacyKey(_ displayID: UInt32) -> String {
        "\(prefix).\(displayID)"
    }

    func bookmarkData(persistentID: String, legacyDisplayID: UInt32) -> Data? {
        let key = stableKey(persistentID)
        if let data = defaults.data(forKey: key) { return data }
        let legacy = legacyKey(legacyDisplayID)
        guard let data = defaults.data(forKey: legacy) else { return nil }
        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacy)
        return data
    }

    func setBookmarkData(_ data: Data, persistentID: String) {
        defaults.set(data, forKey: stableKey(persistentID))
    }

    func clear(persistentID: String, legacyDisplayID: UInt32) {
        defaults.removeObject(forKey: stableKey(persistentID))
        defaults.removeObject(forKey: legacyKey(legacyDisplayID))
    }
}
