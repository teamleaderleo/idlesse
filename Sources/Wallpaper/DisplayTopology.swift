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

    /// Canonical persistence key. Hardware identity survives a live/session UUID
    /// change; ColorSync UUID remains an exact-match signal and the #52 session
    /// alias. Indistinguishable hardware is disambiguated by topology position.
    var durableKey: String {
        let serial = serialNumber == 0 ? "none" : String(serialNumber)
        let foldedName = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let hasHardwareIdentity = vendorID != 0 || modelID != 0 || serialNumber != 0 ||
            physicalWidthMM > 0 || physicalHeightMM > 0
        if hasHardwareIdentity {
            return "hw:\(vendorID):\(modelID):\(serial):\(builtIn ? 1 : 0):\(physicalWidthMM)x\(physicalHeightMM):\(foldedName)"
        }
        if let colorSyncUUID, !colorSyncUUID.isEmpty { return "uuid:\(colorSyncUUID.lowercased())" }
        return "name:\(foldedName)"
    }

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

    func matchScore(to other: DisplayIdentity) -> Int {
        if let lhs = colorSyncUUID, let rhs = other.colorSyncUUID,
           lhs.caseInsensitiveCompare(rhs) == .orderedSame { return 10_000 }
        var score = 0
        if vendorID != 0 && vendorID == other.vendorID { score += 120 }
        if modelID != 0 && modelID == other.modelID { score += 120 }
        if serialNumber != 0 && serialNumber == other.serialNumber { score += 500 }
        if builtIn == other.builtIn { score += 80 }
        if abs(physicalWidthMM - other.physicalWidthMM) <= 3 { score += 60 }
        if abs(physicalHeightMM - other.physicalHeightMM) <= 3 { score += 60 }
        if name.caseInsensitiveCompare(other.name) == .orderedSame { score += 40 }
        return score
    }

    static func bestMatch(for saved: DisplayIdentity, among current: [DisplayIdentity]) -> DisplayIdentity? {
        current.map { ($0, saved.matchScore(to: $0)) }
            .filter { $0.1 >= 300 }
            .max { $0.1 < $1.1 }?.0
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

    func persistentKey(for display: DisplaySnapshot) -> String {
        let base = display.identity.durableKey
        let siblings = displays.filter { $0.identity.durableKey == base }
        guard siblings.count > 1 else { return base }
        let ordered = siblings.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.width != $1.frame.width { return $0.frame.width < $1.frame.width }
            return $0.frame.height < $1.frame.height
        }
        let index = ordered.firstIndex(where: { $0.liveID == display.liveID }) ?? 0
        return "\(base)#\(index)"
    }

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
        return displays.sorted { persistentKey(for: $0) < persistentKey(for: $1) }.map { d in
            let x = Int(((d.frame.minX - union.minX) / safeW * 1000).rounded())
            let y = Int(((d.frame.minY - union.minY) / safeH * 1000).rounded())
            let w = Int((d.frame.width / safeW * 1000).rounded())
            let h = Int((d.frame.height / safeH * 1000).rounded())
            let mirror = d.mirrorMasterID == nil ? "solo" : "mirror"
            return "\(persistentKey(for: d))@\(x),\(y),\(w),\(h),\(mirror)"
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

    @discardableResult
    func record(_ topology: DisplayTopology, now: Date = Date()) -> DisplayArrangementProfile {
        var items = profiles()
        if let index = items.firstIndex(where: { $0.signature == topology.signature }) {
            items[index].lastSeen = now
            save(items)
            return items[index]
        }
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
            memberKeys: Array(topology.displays.map { topology.persistentKey(for: $0) }.sorted().prefix(Self.maxMembersPerProfile)),
            lastSeen: now)
        items.append(profile)
        save(items)
        return profile
    }

    func bestMatch(for topology: DisplayTopology) -> DisplayArrangementProfile? {
        let saved = profiles()
        if let exact = saved.first(where: { $0.signature == topology.signature }) { return exact }
        let current = Set(topology.displays.map { topology.persistentKey(for: $0) })
        var best: DisplayArrangementProfile?
        var bestCount = 0
        for profile in saved {
            let count = Set(profile.memberKeys).intersection(current).count
            guard count > 0 else { continue }
            if count > bestCount || (count == bestCount && (best == nil || profile.lastSeen > best!.lastSeen)) {
                best = profile
                bestCount = count
            }
        }
        return best
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

        let mixed = DisplayTopology(displays: [
            DisplaySnapshot(liveID: 20, identity: builtin, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            pixelWidth: 3024, pixelHeight: 1964, scale: 2, isMain: true, mirrorMasterID: nil),
            DisplaySnapshot(liveID: 21, identity: external, frame: CGRect(x: 1512, y: -98, width: 2560, height: 1440),
                            pixelWidth: 2560, pixelHeight: 1440, scale: 1, isMain: false, mirrorMasterID: nil)
        ])
        let mixedFrames = mixed.normalizedFrames(in: CGSize(width: 700, height: 360))
        precondition(mixedFrames[21]!.height > mixedFrames[20]!.height)

        let reconnectSaved = DisplayIdentity(colorSyncUUID: "OLD-SESSION-UUID", vendorID: 9, modelID: 99, serialNumber: 777,
                                             builtIn: false, physicalWidthMM: 598, physicalHeightMM: 336, name: "Desk")
        let reconnectCurrent = DisplayIdentity(colorSyncUUID: "NEW-SESSION-UUID", vendorID: 9, modelID: 99, serialNumber: 777,
                                               builtIn: false, physicalWidthMM: 598, physicalHeightMM: 336, name: "Desk")
        precondition(reconnectSaved.durableKey == reconnectCurrent.durableKey,
                     "Hardware canonical identity must survive a ColorSync UUID change")
        precondition(DisplayIdentity.bestMatch(for: reconnectSaved, among: [builtin, reconnectCurrent]) == reconnectCurrent)

        let suite = "DisplayTopologySmoke.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let arrangements = KnownDisplayArrangementsStore(defaults: defaults)
        precondition(arrangements.record(one).name == "MacBook Only")
        precondition(arrangements.record(offset).name == "Desk Setup")
        precondition(arrangements.bestMatch(for: offset)?.signature == offset.signature)
    }
}
