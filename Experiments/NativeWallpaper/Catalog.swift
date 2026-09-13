import AppKit
import Foundation
import os

func extensionLog(_ message: String) {
    Logger(subsystem: "dev.idlesse.nativeprobe", category: "catalog").notice("\(message, privacy: .public)")
}

enum ProbeCatalog {
    static func model(poster: URL) -> SettingsViewModels {
        let provider = ChoiceProviderID(rawValue: "dev.idlesse.nativeprobe.catalog")
        let id = ChoiceID(id: "synthetic-orbit", descriptor: .init(provider: provider,
            identifier: "synthetic-orbit", files: [poster], configuration: Data("synthetic-orbit".utf8)))
        let choice = ChoiceDescriptor(id: id, provider: provider, identifier: "synthetic-orbit",
            name: "Synthetic Orbit", localizedDescription: "Idlesse integration test", thumbnail: .image(url: poster),
            isDownloaded: true, options: [])
        let item = SettingsItem(id: id, localizedName: "Synthetic Orbit", thumbnail: .image(url: poster),
            choice: choice, contentBadge: .none, showInTopLevel: true, sortOrder: 0, disposability: .none)
        let group = SettingsGroup(id: GroupID(id: "idlesse-probe"), items: [item],
            localizedName: "Idlesse Lab", disposability: .none, sortOrder: -100,
            sortID: GroupSortID(id: "idlesse-lab"), shouldHideItemLabels: false)
        let desktop = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
        return SettingsViewModels(desktop: desktop, screenSaver: nil)
    }

    /// Only locally authored, fixed data is decoded here; no remote archive is accepted.
    static func boxed(poster: URL) throws -> AnyObject {
        guard let realClass = NSClassFromString("WallpaperSettingsViewModelsXPC") else {
            throw NSError(domain: "IdlesseProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wallpaper model class unavailable"])
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: ShimViewModelsXPC(value: model(poster: poster)), requiringSecureCoding: true)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = true
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(realClass, forClassName: "ShimViewModelsXPC")
        let result = decoder.decodeObject(of: [realClass], forKey: NSKeyedArchiveRootObjectKey)
        decoder.finishDecoding()
        if let error = decoder.error { throw error }
        guard let result else { throw NSError(domain: "IdlesseProbe", code: 2) }
        return result as AnyObject
    }
}
