import Foundation

struct DisplayWallpaperSelection: Equatable {
    var bookmarkData: Data
    var variantID: UUID? = nil
}

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
    private func variantKey(_ persistentID: String) -> String {
        "\(prefix).displayVariant.\(persistentID)"
    }
    private func identityVariantKey(_ durableIdentity: String) -> String {
        "\(prefix).identityVariant.\(durableIdentity)"
    }

    func selection(persistentID: String, legacyDisplayID: UInt32) -> DisplayWallpaperSelection? {
        guard let bookmarkData = bookmarkData(persistentID: persistentID, legacyDisplayID: legacyDisplayID) else { return nil }
        let variantID = defaults.string(forKey: variantKey(persistentID)).flatMap(UUID.init(uuidString:))
            ?? defaults.string(forKey: aliasKey(persistentID)).flatMap { defaults.string(forKey: identityVariantKey($0)) }.flatMap(UUID.init(uuidString:))
        return DisplayWallpaperSelection(bookmarkData: bookmarkData, variantID: variantID)
    }

    func setSelection(_ selection: DisplayWallpaperSelection, persistentID: String) {
        setBookmarkData(selection.bookmarkData, persistentID: persistentID)
        if let variantID = selection.variantID {
            defaults.set(variantID.uuidString, forKey: variantKey(persistentID))
            if let durable = defaults.string(forKey: aliasKey(persistentID)) {
                defaults.set(variantID.uuidString, forKey: identityVariantKey(durable))
            }
        } else {
            defaults.removeObject(forKey: variantKey(persistentID))
            if let durable = defaults.string(forKey: aliasKey(persistentID)) {
                defaults.removeObject(forKey: identityVariantKey(durable))
            }
        }
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
        defaults.removeObject(forKey: variantKey(persistentID))
        if let durable = defaults.string(forKey: aliasKey(persistentID)) {
            defaults.removeObject(forKey: identityKey(durable))
            defaults.removeObject(forKey: identityVariantKey(durable))
        }
        defaults.removeObject(forKey: aliasKey(persistentID))
    }

    /// Link the current #52 session identifier to canonical display identity.
    /// `previousIdentityKey` is supplied only after the persisted identity
    /// registry produced a unique reconnect match; ambiguous monitors therefore
    /// cannot borrow each other's bookmark.
    @discardableResult
    func reconcile(identityKey durableIdentity: String,
                   previousIdentityKey: String? = nil,
                   persistentID: String,
                   legacyDisplayID: UInt32) -> Data? {
        let durableKey = identityKey(durableIdentity)
        let previousKey = previousIdentityKey.flatMap { previous in
            previous == durableIdentity ? nil : identityKey(previous)
        }
        let sessionKey = stableKey(persistentID)
        let oldKey = legacyKey(legacyDisplayID)

        var data = defaults.data(forKey: durableKey)
        if data == nil, let previousKey { data = defaults.data(forKey: previousKey) }
        if data == nil { data = defaults.data(forKey: sessionKey) }
        if data == nil { data = defaults.data(forKey: oldKey) }

        guard let data else {
            defaults.set(durableIdentity, forKey: aliasKey(persistentID))
            return nil
        }
        defaults.set(data, forKey: durableKey)
        defaults.set(data, forKey: sessionKey)
        defaults.set(durableIdentity, forKey: aliasKey(persistentID))
        let variant = defaults.string(forKey: identityVariantKey(durableIdentity))
            ?? previousIdentityKey.flatMap { defaults.string(forKey: identityVariantKey($0)) }
            ?? defaults.string(forKey: variantKey(persistentID))
        if let variant {
            defaults.set(variant, forKey: identityVariantKey(durableIdentity))
            defaults.set(variant, forKey: variantKey(persistentID))
        }
        defaults.removeObject(forKey: oldKey)
        return data
    }

    func clear(identityKey durableIdentity: String, persistentID: String, legacyDisplayID: UInt32) {
        defaults.removeObject(forKey: identityKey(durableIdentity))
        defaults.removeObject(forKey: identityVariantKey(durableIdentity))
        defaults.removeObject(forKey: stableKey(persistentID))
        defaults.removeObject(forKey: variantKey(persistentID))
        defaults.removeObject(forKey: legacyKey(legacyDisplayID))
        defaults.removeObject(forKey: aliasKey(persistentID))
    }

    private func mirrorToIdentity(_ data: Data, persistentID: String) {
        guard let durable = defaults.string(forKey: aliasKey(persistentID)) else { return }
        defaults.set(data, forKey: identityKey(durable))
        if let variant = defaults.string(forKey: variantKey(persistentID)) {
            defaults.set(variant, forKey: identityVariantKey(durable))
        }
    }
}
