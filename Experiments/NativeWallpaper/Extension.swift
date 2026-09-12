import Foundation
import ExtensionFoundation
import Security
import os

@objc protocol ProbeWallpaperProtocol {
    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettings(_ types: Any?, reply: @escaping (Any?, NSError?) -> Void)
    @objc(acquireWithId:request:reply:)
    func acquire(_ id: Any?, request: Any?, reply: @escaping (Any?, NSError?) -> Void)
    @objc(updateWithId:request:reply:)
    func update(_ id: Any?, request: Any?, reply: @escaping (NSError?) -> Void)
    @objc(invalidateWithId:reply:)
    func invalidate(_ id: Any?, reply: @escaping (NSError?) -> Void)
    @objc(snapshotWithId:reply:)
    func snapshot(_ id: Any?, reply: @escaping (Any?, NSError?) -> Void)
    @objc(selectedChoicesDidChangeFor:reply:)
    func selected(_ id: Any?, reply: @escaping (NSError?) -> Void)
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
        for name in ["WallpaperContentTypeSetXPC", "WallpaperSettingsViewModelsXPC", "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperChoiceIDXPC", "WallpaperUpdateRequestXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC"] {
            guard let type = NSClassFromString(name) else { extensionLog("Required XPC class missing: \(name)"); return false }
            classSet.add(type)
        }
        let classes = classSet as! Set<AnyHashable>
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.provideSettings(_:reply:)), argumentIndex: 0, ofReply: false)
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.provideSettings(_:reply:)), argumentIndex: 0, ofReply: true)
        for index in 0...1 { interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.acquire(_:request:reply:)), argumentIndex: index, ofReply: false) }
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.downloaded(_:reply:)), argumentIndex: 0, ofReply: false)
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.acquire(_:request:reply:)), argumentIndex: 0, ofReply: true)
        for index in 0...1 { interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.update(_:request:reply:)), argumentIndex: index, ofReply: false) }
        for selector in [#selector(ProbeWallpaperProtocol.invalidate(_:reply:)), #selector(ProbeWallpaperProtocol.snapshot(_:reply:)), #selector(ProbeWallpaperProtocol.selected(_:reply:))] {
            interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: false)
        }
        interface.setClasses(classes, for: #selector(ProbeWallpaperProtocol.snapshot(_:reply:)), argumentIndex: 0, ofReply: true)
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
        perform(id, reply: reply) { key in
            guard let request else { throw probeError("Missing creation request") }
            return try ProbeSurfaceStore.shared.acquire(id: key, geometry: ProbeGeometry(request))
        }
    }
    func update(_ id: Any?, request: Any?, reply: @escaping (NSError?) -> Void) {
        perform(id, reply: { _, error in reply(error) }) { key in
            guard let request else { throw probeError("Missing update request") }
            try ProbeSurfaceStore.shared.update(id: key, request: request); return nil
        }
    }
    func invalidate(_ id: Any?, reply: @escaping (NSError?) -> Void) {
        perform(id, reply: { _, error in reply(error) }) { key in
            ProbeSurfaceStore.shared.invalidate(id: key); return nil
        }
    }
    func snapshot(_ id: Any?, reply: @escaping (Any?, NSError?) -> Void) {
        perform(id, reply: reply) { key in
            let snapshot = try ProbeSurfaceStore.shared.snapshot(id: key)
            extensionLog("Serving synthetic IOSurface snapshot")
            return snapshot
        }
    }
    func selected(_ id: Any?, reply: @escaping (NSError?) -> Void) { reply(nil) }
    private func perform(_ id: Any?, reply: @escaping (Any?, NSError?) -> Void,
                         body: @escaping (UUID) throws -> AnyObject?) {
        guard let id, let key = probeUUID(id) else {
            extensionLog("Request rejected: missing surface UUID")
            reply(nil, probeError("Missing surface UUID")); return
        }
        ProbeSurfaceStore.shared.queue.async {
            do { reply(try body(key), nil) }
            catch { extensionLog("Surface request failed: \(error)"); reply(nil, error as NSError) }
        }
    }
    func downloaded(_ id: Any?, reply: @escaping (Bool, NSError?) -> Void) { reply(true, nil) }
}
