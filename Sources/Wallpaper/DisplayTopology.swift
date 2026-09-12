import AppKit
import CoreGraphics
import Foundation

struct DisplayIdentity: Codable, Hashable {
    var colorSyncUUID: String?
    var vendorID: UInt32
    var modelID: UInt32
    var serialNumber: UInt32
    var builtIn: Bool
    var physicalWidthMM: Int
    var physicalHeightMM: Int
    var name: String

    /// Hardware/device identity only. Localized display names are presentation
    /// text and never participate in persistence identity.
    var deviceKey: String {
        if serialNumber != 0 {
            return "serial:\(vendorID):\(modelID):\(serialNumber):\(builtIn ? 1 : 0)"
        }
        let width = Self.dimensionBucket(physicalWidthMM)
        let height = Self.dimensionBucket(physicalHeightMM)
        let hasHardwareEvidence = vendorID != 0 || modelID != 0 || width != 0 || height != 0
        if hasHardwareEvidence {
            return "hw:\(vendorID):\(modelID):none:\(builtIn ? 1 : 0):\(width)x\(height)"
        }
        if let colorSyncUUID, !colorSyncUUID.isEmpty {
            return "uuid:\(colorSyncUUID.lowercased())"
        }
        return "anonymous:\(builtIn ? 1 : 0)"
    }

    /// Compatibility name for callers introduced before device/slot identity
    /// were split explicitly.
    var durableKey: String { deviceKey }

    static func capture(screen: NSScreen, displayID: UInt32) -> DisplayIdentity {
        let cgID = CGDirectDisplayID(displayID)
        let uuid: String?
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(cgID) {
            uuid = CFUUIDCreateString(kCFAllocatorDefault, unmanaged.takeRetainedValue()) as String
        } else {
            uuid = nil
        }
        let mm = CGDisplayScreenSize(cgID)
        return DisplayIdentity(
            colorSyncUUID: uuid,
            vendorID: CGDisplayVendorNumber(cgID),
            modelID: CGDisplayModelNumber(cgID),
            serialNumber: CGDisplaySerialNumber(cgID),
            builtIn: CGDisplayIsBuiltin(cgID) != 0,
            physicalWidthMM: Int(mm.width.rounded()),
            physicalHeightMM: Int(mm.height.rounded()),
            name: screen.localizedName
        )
    }

    /// Higher values mean a safer reconnect match. Known serial/vendor/model
    /// conflicts reject immediately. Serial-less automatic matching requires
    /// vendor/model plus both physical dimensions (within a small EDID drift),
    /// or an exact ColorSync UUID.
    func matchScore(to other: DisplayIdentity) -> Int {
        if serialNumber != 0, other.serialNumber != 0, serialNumber != other.serialNumber { return 0 }
        if vendorID != 0, other.vendorID != 0, vendorID != other.vendorID { return 0 }
        if modelID != 0, other.modelID != 0, modelID != other.modelID { return 0 }

        var score = 0
        if let lhs = colorSyncUUID, let rhs = other.colorSyncUUID,
           lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            score += 2_000
        }
        if serialNumber != 0, serialNumber == other.serialNumber { score += 1_000 }
        if vendorID != 0, vendorID == other.vendorID { score += 160 }
        if modelID != 0, modelID == other.modelID { score += 160 }
        if builtIn == other.builtIn { score += 80 }
        if physicalWidthMM > 0, other.physicalWidthMM > 0,
           abs(physicalWidthMM - other.physicalWidthMM) <= 4 { score += 100 }
        if physicalHeightMM > 0, other.physicalHeightMM > 0,
           abs(physicalHeightMM - other.physicalHeightMM) <= 4 { score += 100 }
        // Useful only as a final tie-break hint; it cannot lift weak hardware
        // evidence across the automatic-match threshold.
        if name.caseInsensitiveCompare(other.name) == .orderedSame { score += 5 }
        return score
    }

    /// Return only a unique high-confidence device match. Equal best candidates
    /// are intentionally rejected so identical serial-less panels never steal
    /// each other's assignment.
    static func bestMatch(for saved: DisplayIdentity, among current: [DisplayIdentity]) -> DisplayIdentity? {
        var best: DisplayIdentity?
        var bestScore = 0
        var ambiguous = false
        for candidate in current.prefix(32) {
            let score = saved.matchScore(to: candidate)
            guard score >= 550 else { continue }
            if score > bestScore {
                best = candidate
                bestScore = score
                ambiguous = false
            } else if score == bestScore {
                ambiguous = true
            }
        }
        return ambiguous ? nil : best
    }

    private static func dimensionBucket(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        return Int((Double(value) / 10.0).rounded()) * 10
    }
}

struct PersistedDisplayIdentity: Codable, Equatable {
    var assignmentKey: String
    var identity: DisplayIdentity
    var lastSeen: Date
}

/// Bounded registry used only to bridge reconnects where session UUID or EDID
/// details shift. Assignment bytes stay in DisplayAssignmentStore.
struct DisplayIdentityStore {
    private static let maxRecords = 32
    var defaults: UserDefaults
    var prefix: String

    private var storageKey: String { "\(prefix).identities.v1" }

    func records() -> [PersistedDisplayIdentity] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PersistedDisplayIdentity].self, from: data) else { return [] }
        return Array(decoded.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxRecords))
    }

    func previousAssignmentKey(for current: DisplayIdentity, proposedKey: String) -> String? {
        let saved = records()
        if saved.contains(where: { $0.assignmentKey == proposedKey }) { return proposedKey }

        var bestKey: String?
        var bestScore = 0
        var ambiguous = false
        for record in saved {
            let score = record.identity.matchScore(to: current)
            guard score >= 550 else { continue }
            if score > bestScore {
                bestScore = score
                bestKey = record.assignmentKey
                ambiguous = false
            } else if score == bestScore {
                ambiguous = true
            }
        }
        return ambiguous ? nil : bestKey
    }

    func remember(_ identity: DisplayIdentity, assignmentKey: String, now: Date = Date()) {
        var saved = records().filter { $0.assignmentKey != assignmentKey }
        saved.append(PersistedDisplayIdentity(assignmentKey: assignmentKey, identity: identity, lastSeen: now))
        save(saved)
    }

    private func save(_ records: [PersistedDisplayIdentity]) {
        let bounded = Array(records.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxRecords))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct DisplaySnapshot {
    var liveID: UInt32
    var identity: DisplayIdentity
    var frame: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: CGFloat
    var isMain: Bool
    var mirrorMasterID: UInt32?

    var resolutionDescription: String { "\(pixelWidth) × \(pixelHeight)" }
}

struct DisplayTopology {
    var displays: [DisplaySnapshot]

    static func current() -> DisplayTopology {
        let displays = NSScreen.screens.compactMap { screen -> DisplaySnapshot? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            let cgID = CGDirectDisplayID(displayID)
            let mode = CGDisplayCopyDisplayMode(cgID)
            let mirror = CGDisplayMirrorsDisplay(cgID)
            return DisplaySnapshot(
                liveID: displayID,
                identity: .capture(screen: screen, displayID: displayID),
                frame: screen.frame,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                scale: screen.backingScaleFactor,
                isMain: CGDisplayIsMain(cgID) != 0,
                mirrorMasterID: mirror == kCGNullDirectDisplay ? nil : UInt32(mirror)
            )
        }
        return DisplayTopology(displays: displays)
    }

    var desktopFrame: CGRect { displays.reduce(CGRect.null) { $0.union($1.frame) } }
    var independentDisplays: [DisplaySnapshot] { displays.filter { $0.mirrorMasterID == nil } }

    func master(for display: DisplaySnapshot) -> DisplaySnapshot {
        guard let masterID = display.mirrorMasterID,
              let master = displays.first(where: { $0.liveID == masterID }) else { return display }
        return master
    }

    func deviceKey(for display: DisplaySnapshot) -> String { display.identity.deviceKey }

    /// Position within this remembered desk arrangement. For uniquely
    /// identifiable hardware this equals deviceKey. Indistinguishable siblings
    /// intentionally follow left/right (or top/bottom) desk slots.
    func slotKey(for display: DisplaySnapshot) -> String {
        let base = deviceKey(for: display)
        let siblings = displays.filter { deviceKey(for: $0) == base }
        guard siblings.count > 1 else { return base }
        let ordered = siblings.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.width != $1.frame.width { return $0.frame.width < $1.frame.width }
            if $0.frame.height != $1.frame.height { return $0.frame.height < $1.frame.height }
            if $0.isMain != $1.isMain { return $0.isMain && !$1.isMain }
            return $0.liveID < $1.liveID
        }
        let index = ordered.firstIndex(where: { $0.liveID == display.liveID }) ?? 0
        return "\(base)#\(index)"
    }

    /// Compatibility name for assignment-plan callers; persistence here is a
    /// desk slot when hardware itself is indistinguishable.
    func persistentKey(for display: DisplaySnapshot) -> String { slotKey(for: display) }

    /// Preserve actual AppKit desktop geometry: negative origins, gaps, offsets,
    /// portrait displays and different point sizes all survive normalization.
    func normalizedFrames(in canvas: CGSize, padding: CGFloat = 12) -> [UInt32: CGRect] {
        let union = desktopFrame
        guard !union.isNull, union.width > 0, union.height > 0,
              canvas.width > padding * 2, canvas.height > padding * 2 else { return [:] }
        let usable = CGSize(width: canvas.width - padding * 2, height: canvas.height - padding * 2)
        let scale = min(usable.width / union.width, usable.height / union.height)
        let drawn = CGSize(width: union.width * scale, height: union.height * scale)
        let origin = CGPoint(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2)
        return Dictionary(uniqueKeysWithValues: displays.map { display in
            let f = display.frame
            return (display.liveID, CGRect(
                x: origin.x + (f.minX - union.minX) * scale,
                y: origin.y + (f.minY - union.minY) * scale,
                width: max(18, f.width * scale),
                height: max(12, f.height * scale)))
        })
    }

    var signature: String {
        let union = desktopFrame
        let safeW = max(1, union.width)
        let safeH = max(1, union.height)
        return displays.sorted { slotKey(for: $0) < slotKey(for: $1) }.map { display in
            let x = Int(((display.frame.minX - union.minX) / safeW * 1000).rounded())
            let y = Int(((display.frame.minY - union.minY) / safeH * 1000).rounded())
            let w = Int((display.frame.width / safeW * 1000).rounded())
            let h = Int((display.frame.height / safeH * 1000).rounded())
            let mirror = display.mirrorMasterID == nil ? "solo" : "mirror"
            return "\(slotKey(for: display))@\(x),\(y),\(w),\(h),\(mirror)"
        }.joined(separator: "|")
    }
}

enum DisplayAssignmentMode: String, Codable { case sameOnAll, perDisplay, desktopSpan }

struct ResolvedDisplayAssignment {
    var persistentKey: String
    var liveID: UInt32
    var sourceURL: URL?
    var explicit: Bool
    var mirroredFrom: UInt32?
}

struct ResolvedWallpaperAssignmentPlan {
    var mode: DisplayAssignmentMode
    var topology: DisplayTopology
    var assignments: [ResolvedDisplayAssignment]

    func assignment(for liveID: UInt32) -> ResolvedDisplayAssignment? {
        assignments.first { $0.liveID == liveID }
    }
}

struct DisplayArrangementProfile: Codable, Equatable {
    var id: UUID
    var name: String
    var signature: String
    var memberKeys: [String]
    var lastSeen: Date
}

struct KnownDisplayArrangementsStore {
    private static let key = "wallpaper.displayArrangements.v1"
    private static let maxProfiles = 16
    private static let maxMembersPerProfile = 16
    var defaults: UserDefaults

    func profiles() -> [DisplayArrangementProfile] {
        guard let data = defaults.data(forKey: Self.key),
              let result = try? JSONDecoder().decode([DisplayArrangementProfile].self, from: data) else { return [] }
        return Array(result.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxProfiles))
    }

    func exactMatch(for topology: DisplayTopology) -> DisplayArrangementProfile? {
        profiles().first { $0.signature == topology.signature }
    }

    /// Seen topology may refresh an exact known profile's LRU timestamp. Unknown
    /// cable/dock intermediate states never become profiles by observation.
    @discardableResult
    func touchKnown(_ topology: DisplayTopology, now: Date = Date()) -> DisplayArrangementProfile? {
        var items = profiles()
        guard let match = exactMatch(for: topology),
              let index = items.firstIndex(where: { $0.id == match.id }) else { return nil }
        items[index].lastSeen = now
        let profile = items[index]
        save(items)
        return profile
    }

    /// Explicit user save signal for the settled current topology.
    @discardableResult
    func saveCurrent(_ topology: DisplayTopology, now: Date = Date()) -> DisplayArrangementProfile {
        if let known = touchKnown(topology, now: now) { return known }
        var items = profiles()
        let independent = topology.independentDisplays
        let suggested: String
        if independent.count == 1, independent.first?.identity.builtIn == true {
            suggested = "MacBook Only"
        } else if independent.count > 1 {
            suggested = "Desk Setup"
        } else {
            suggested = "Display Setup"
        }
        let existingNames = Set(items.map(\.name))
        var name = suggested
        var suffix = 2
        while existingNames.contains(name) {
            name = "\(suggested) \(suffix)"
            suffix += 1
        }
        let profile = DisplayArrangementProfile(
            id: UUID(), name: name, signature: topology.signature,
            memberKeys: Array(topology.displays.map { topology.slotKey(for: $0) }.sorted().prefix(Self.maxMembersPerProfile)),
            lastSeen: now)
        items.append(profile)
        save(items)
        return profile
    }

    /// Discovery only. Partial member overlap may suggest a remembered desk
    /// setup in UI, but automatic restoration must use exactMatch/touchKnown.
    func suggestedMatch(for topology: DisplayTopology) -> DisplayArrangementProfile? {
        if let exact = exactMatch(for: topology) { return exact }
        let current = Set(topology.displays.map { topology.slotKey(for: $0) })
        var best: DisplayArrangementProfile?
        var bestCount = 0
        for profile in profiles() {
            let count = Set(profile.memberKeys).intersection(current).count
            guard count > 0 else { continue }
            if count > bestCount || (count == bestCount && (best == nil || profile.lastSeen > best!.lastSeen)) {
                best = profile
                bestCount = count
            }
        }
        return best
    }

    @available(*, deprecated, message: "Use suggestedMatch for UI hints; exactMatch for automatic restoration")
    func bestMatch(for topology: DisplayTopology) -> DisplayArrangementProfile? {
        suggestedMatch(for: topology)
    }

    private func save(_ profiles: [DisplayArrangementProfile]) {
        let bounded = Array(profiles.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxProfiles))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

enum DisplayTopologySmoke {
    static func run() {
        let builtin = DisplayIdentity(colorSyncUUID: "BUILTIN", vendorID: 1, modelID: 10, serialNumber: 1,
                                      builtIn: true, physicalWidthMM: 300, physicalHeightMM: 190, name: "Built-in")
        let external = DisplayIdentity(colorSyncUUID: "EXT", vendorID: 2, modelID: 20, serialNumber: 2,
                                       builtIn: false, physicalWidthMM: 600, physicalHeightMM: 340, name: "External")
        let one = DisplayTopology(displays: [
            DisplaySnapshot(liveID: 1, identity: builtin, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                            pixelWidth: 2880, pixelHeight: 1800, scale: 2, isMain: true, mirrorMasterID: nil)
        ])
        precondition(one.normalizedFrames(in: CGSize(width: 500, height: 300)).count == 1)

        let offset = DisplayTopology(displays: one.displays + [
            DisplaySnapshot(liveID: 2, identity: external, frame: CGRect(x: -1920, y: 180, width: 1920, height: 1080),
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: false, mirrorMasterID: nil)
        ])
        let offsetFrames = offset.normalizedFrames(in: CGSize(width: 600, height: 360))
        precondition(offsetFrames[2]!.minX < offsetFrames[1]!.minX)
        precondition(offsetFrames[2]!.minY > offsetFrames[1]!.minY)

        let mirror = DisplayTopology(displays: [
            DisplaySnapshot(liveID: 10, identity: external, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            pixelWidth: 3840, pixelHeight: 2160, scale: 2, isMain: true, mirrorMasterID: nil),
            DisplaySnapshot(liveID: 11, identity: external, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: false, mirrorMasterID: 10)
        ])
        precondition(mirror.master(for: mirror.displays[1]).liveID == 10)

        let reconnectSaved = DisplayIdentity(colorSyncUUID: "OLD-UUID", vendorID: 9, modelID: 99, serialNumber: 777,
                                             builtIn: false, physicalWidthMM: 598, physicalHeightMM: 336, name: "Desk")
        let reconnectCurrent = DisplayIdentity(colorSyncUUID: "NEW-UUID", vendorID: 9, modelID: 99, serialNumber: 777,
                                               builtIn: false, physicalWidthMM: 602, physicalHeightMM: 338, name: "Écran")
        precondition(reconnectSaved.deviceKey == reconnectCurrent.deviceKey,
                     "Serial-backed device identity must survive UUID, locale/name and size-report churn")
        precondition(DisplayIdentity.bestMatch(for: reconnectSaved, among: [builtin, reconnectCurrent]) == reconnectCurrent)

        let seriallessSaved = DisplayIdentity(colorSyncUUID: nil, vendorID: 7, modelID: 70, serialNumber: 0,
                                              builtIn: false, physicalWidthMM: 520, physicalHeightMM: 290, name: "Twin")
        let seriallessNear = DisplayIdentity(colorSyncUUID: "NEAR", vendorID: 7, modelID: 70, serialNumber: 0,
                                             builtIn: false, physicalWidthMM: 523, physicalHeightMM: 288, name: "Renamed")
        let seriallessFar = DisplayIdentity(colorSyncUUID: "FAR", vendorID: 7, modelID: 70, serialNumber: 0,
                                            builtIn: false, physicalWidthMM: 560, physicalHeightMM: 290, name: "Twin")
        precondition(DisplayIdentity.bestMatch(for: seriallessSaved, among: [seriallessNear]) == seriallessNear)
        precondition(DisplayIdentity.bestMatch(for: seriallessSaved, among: [seriallessFar]) == nil,
                     "Large physical-size changes must not auto-match a serial-less same-model panel")

        let twinA = DisplayIdentity(colorSyncUUID: "TWIN-A", vendorID: 7, modelID: 70, serialNumber: 0,
                                    builtIn: false, physicalWidthMM: 520, physicalHeightMM: 290, name: "Twin A")
        let twinB = DisplayIdentity(colorSyncUUID: "TWIN-B", vendorID: 7, modelID: 70, serialNumber: 0,
                                    builtIn: false, physicalWidthMM: 520, physicalHeightMM: 290, name: "Twin B")
        precondition(DisplayIdentity.bestMatch(for: seriallessSaved, among: [twinA, twinB]) == nil,
                     "Identical serial-less siblings must remain ambiguous")
        let twins = DisplayTopology(displays: [
            DisplaySnapshot(liveID: 101, identity: twinA, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: true, mirrorMasterID: nil),
            DisplaySnapshot(liveID: 102, identity: twinB, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: false, mirrorMasterID: nil)
        ])
        precondition(twins.deviceKey(for: twins.displays[0]) == twins.deviceKey(for: twins.displays[1]))
        precondition(twins.slotKey(for: twins.displays[0]).hasSuffix("#0"))
        precondition(twins.slotKey(for: twins.displays[1]).hasSuffix("#1"))
        let restartedTwins = DisplayTopology(displays: [
            DisplaySnapshot(liveID: 501, identity: twinA, frame: twins.displays[0].frame,
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: true, mirrorMasterID: nil),
            DisplaySnapshot(liveID: 502, identity: twinB, frame: twins.displays[1].frame,
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: false, mirrorMasterID: nil)
        ])
        precondition(twins.signature == restartedTwins.signature,
                     "Changing live CG display IDs must not change persisted desk-slot identity")

        let suite = "DisplayTopologySmoke.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let arrangements = KnownDisplayArrangementsStore(defaults: defaults)
        precondition(arrangements.touchKnown(one) == nil, "Observation must not save a new arrangement")
        let laptop = arrangements.saveCurrent(one)
        precondition(laptop.name == "MacBook Only")
        precondition(arrangements.exactMatch(for: one)?.id == laptop.id)
        precondition(arrangements.touchKnown(offset) == nil)
        let desk = arrangements.saveCurrent(offset)
        precondition(desk.name == "Desk Setup")
        precondition(arrangements.exactMatch(for: offset)?.id == desk.id)

        let externalOnly = DisplayTopology(displays: [
            DisplaySnapshot(liveID: 2, identity: external, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                            pixelWidth: 1920, pixelHeight: 1080, scale: 1, isMain: true, mirrorMasterID: nil)
        ])
        precondition(arrangements.exactMatch(for: externalOnly) == nil,
                     "A partial dock state must never count as an automatic arrangement restore")
        precondition(arrangements.suggestedMatch(for: externalOnly)?.id == desk.id,
                     "Partial overlap may still offer a remembered setup as a UI suggestion")

        let identities = DisplayIdentityStore(defaults: defaults, prefix: "displaySmoke")
        identities.remember(reconnectSaved, assignmentKey: reconnectSaved.deviceKey)
        precondition(identities.previousAssignmentKey(for: reconnectCurrent,
                                                       proposedKey: reconnectCurrent.deviceKey) == reconnectSaved.deviceKey)
        identities.remember(twinA, assignmentKey: "twin-a")
        identities.remember(twinB, assignmentKey: "twin-b")
        precondition(identities.previousAssignmentKey(for: seriallessSaved, proposedKey: "new-twin") == nil)
    }
}
