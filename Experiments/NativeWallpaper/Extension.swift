import Foundation
import ExtensionFoundation
import Security
import os

@objc protocol ProbeWallpaperProtocol {
    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettings(_ types: Any?, reply: @escaping (Any?, NSError?) -> Void)
    @objc(acquireWithId:request:reply:)
    func acquire(_ id: Any?, request: Any?, reply: @escaping (Any?, NSError?) -> Void)
    @objc(isChoiceDownloadedWith:reply:)
    func downloaded(_ id: Any?, reply: @escaping (Bool, NSError?) -> Void)
}

@main
final class NativeWallpaperProbe: NSObject, AppExtension {
    override required init() {
        super.init()
        _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY)
        extensionLog("Extension initialized")
    }
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onConnection: ProbeConfiguration().accept)
    }
}
struct ProbeConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extensionLog("Host connection reached configuration")
        guard connection.responds(to: NSSelectorFromString("auditToken")) else { extensionLog("Audit-token accessor unavailable; rejected"); return false }
        var token = connection.auditToken
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.wallpaper.agent\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            extensionLog("Host identity could not be verified; rejected")
            return false
        }
        let interface = NSXPCInterface(with: ProbeWallpaperProtocol.self)
        let classSet = NSMutableSet(array: [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self])
        for name in ["WallpaperContentTypeSetXPC", "WallpaperSettingsViewModelsXPC", "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperChoiceIDXPC"] {
            guard let type = NSClassFromString(name) else { extensionLog("Required XPC class missing: \(name)"); return false }
            classSet.add(type)
        }
        let classes = classSet as! Set<AnyHashable>
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.provideSettings(_:reply:)), argumentIndex: 0, ofReply: false)
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.provideSettings(_:reply:)), argumentIndex: 0, ofReply: true)
        for index in 0...1 { interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.acquire(_:request:reply:)), argumentIndex: index, ofReply: false) }
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.downloaded(_:reply:)), argumentIndex: 0, ofReply: false)
        connection.exportedInterface = interface
        connection.exportedObject = ProbeHandler()
        connection.resume()
        extensionLog("Verified WallpaperAgent connection accepted")
        return true
    }
}
final class ProbeHandler: NSObject, ProbeWallpaperProtocol {
    func provideSettings(_ types: Any?, reply: @escaping (Any?, NSError?) -> Void) {
        do {
            guard let poster = Bundle.main.url(forResource: "SyntheticOrbit", withExtension: "png") else { throw NSError(domain: "IdlesseProbe", code: 3) }
            let model = try ProbeCatalog.boxed(poster: poster)
            extensionLog("Serving Synthetic Orbit settings tile")
            reply(model, nil)
        } catch { extensionLog("Catalog failed: \(error)"); reply(nil, error as NSError) }
    }
    func acquire(_ id: Any?, request: Any?, reply: @escaping (Any?, NSError?) -> Void) {
        extensionLog("Acquire rejected: rendering is not implemented in this catalog probe")
        reply(nil, NSError(domain: "IdlesseProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Catalog probe only; renderer not yet implemented."]))
    }
    func downloaded(_ id: Any?, reply: @escaping (Bool, NSError?) -> Void) { reply(true, nil) }
}
