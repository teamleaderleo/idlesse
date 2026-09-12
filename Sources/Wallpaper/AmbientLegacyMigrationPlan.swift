import Foundation

/// Produces the initial priority order for an explicit legacy cutover after
/// scene URLs have been adapted to stable Library IDs by the host.
struct AmbientLegacyMigrationPlan {
    static func make(collections: [AmbientLegacyCollectionSchedule],
                     followsSun: Bool,
                     nightSceneID: String?,
                     bedtime: AmbientLegacyBedtime?) throws -> [AmbientSet] {
        let collectionSets = collections.compactMap(AmbientLegacyAdapter.collectionSet)
        guard collectionSets.count == collections.count else { throw AmbientSetActuationError.invalidLegacySchedule }
        var result: [AmbientSet] = []

        if let bedtime, bedtime.enabled {
            // Legacy Bedtime and collection schedules can coexist because the
            // old controllers compose dimming with collection playback. The
            // one-winner Ambient Sets rule needs an explicit wallpaper target
            // to reproduce that overlap safely.
            if nightSceneID == nil && !collectionSets.isEmpty {
                throw AmbientSetActuationError.unsafeLegacyBedtimeOverlap
            }
            var adapted = bedtime
            adapted.nightSceneID = nightSceneID
            if let set = AmbientLegacyAdapter.bedtimeSet(from: adapted) { result.append(set) }
        }

        if followsSun, let nightSceneID,
           let set = AmbientLegacyAdapter.dayNightSet(from: .init(nightSceneID: nightSceneID, followsSun: true)) {
            result.append(set)
        }

        result.append(contentsOf: collectionSets)
        return result
    }
}
