import AppKit
import IOSurface
import ObjectiveC

/// Experimental adapters for the installed macOS 26 framework only. No guessed
/// offsets: require the observed named ivars and exact instance sizes. These
/// private Swift wrappers do not expose Objective-C value initializers.
/// Protocol/layout reference: Phosphene RuntimeHelpers.swift (MIT; see Vendor).
enum ProbeWire {
    static func storage(_ name: String, ivar: String) throws -> (AnyObject, UnsafeMutableRawPointer) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
              let cls = NSClassFromString(name), class_getInstanceSize(cls) == 16,
              let slot = class_getInstanceVariable(cls, ivar), ivar_getOffset(slot) == 8,
              let object = class_createInstance(cls, 0) else {
            throw probeError("Unsupported \(name) layout")
        }
        return (object as AnyObject, Unmanaged.passUnretained(object as AnyObject).toOpaque().advanced(by: ivar_getOffset(slot)))
    }
    static func context(_ id: UInt32) throws -> AnyObject {
        guard id != 0 else { throw probeError("Empty remote context") }
        let (object, pointer) = try storage("WallpaperRemoteContextXPC", ivar: "box")
        pointer.storeBytes(of: id, as: UInt32.self)
        return object
    }
    static func snapshot(_ surface: IOSurface) throws -> AnyObject {
        let (object, pointer) = try storage("WallpaperSnapshotXPC", ivar: "rawValue")
        // The wrapper's Swift destructor owns/releases this reference.
        pointer.storeBytes(of: Unmanaged.passRetained(surface).toOpaque(), as: UnsafeMutableRawPointer.self)
        return object
    }
}
func probeError(_ text: String) -> NSError {
    NSError(domain: "IdlesseProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: text])
}

/// Read only named metadata from Apple's opaque Swift request. Bounded traversal
/// avoids relying on a string dump or touching files supplied by the host.
func probeField(_ name: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == name { return child.value }
        if let found = probeField(name, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}
func probeUUID(_ value: Any, depth: Int = 0) -> UUID? {
    if let uuid = value as? UUID { return uuid }
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if let uuid = probeUUID(child.value, depth: depth + 1) { return uuid }
    }
    return nil
}
struct ProbeGeometry {
    var size: CGSize
    var scale: CGFloat
    var display: UInt32?
    init(_ request: Any) throws {
        guard let destination = probeField("destination", in: request),
              let size = probeField("size", in: destination) as? CGSize else {
            throw probeError("Missing destination size")
        }
        let scale = probeField("scaleFactor", in: destination) as? CGFloat ?? 1
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width >= 1, size.height >= 1, scale >= 1, scale <= 4,
              size.width * scale <= 8192, size.height * scale <= 8192,
              size.width * size.height * scale * scale <= 34_000_000 else {
            throw probeError("Destination exceeds synthetic probe budget")
        }
        self.size = size; self.scale = scale
        display = probeField("directDisplayID", in: destination) as? UInt32
    }
}

final class ProbeSurface {
    let context: CAContext
    let root = CALayer()
    private let ring = CAShapeLayer()
    private let orbit = CALayer()
    private let dot = CALayer()
    private(set) var geometry: ProbeGeometry
    private var pausedAt: CFTimeInterval?
    private let started = CACurrentMediaTime()
    private var pausedDuration: CFTimeInterval = 0
    var elapsed: CFTimeInterval { (pausedAt ?? CACurrentMediaTime()) - started - pausedDuration }

    init(geometry: ProbeGeometry) throws {
        self.geometry = geometry
        guard let cls = NSClassFromString("CAContext"),
              class_getClassMethod(cls, NSSelectorFromString("remoteContextWithOptions:")) != nil else {
            throw probeError("Remote layer API unavailable")
        }
        var options: [String: Any] = [:]
        if let display = geometry.display { options["displayId"] = display }
        guard let context = CAContext.remoteContext(withOptions: options) as? CAContext,
              context.contextId != 0 else { throw probeError("Remote context creation failed") }
        self.context = context
        root.backgroundColor = CGColor(red: 0.04, green: 0.07, blue: 0.16, alpha: 1)
        ring.fillColor = nil
        ring.strokeColor = CGColor(red: 0.4, green: 0.8, blue: 0.9, alpha: 1)
        dot.backgroundColor = CGColor(red: 1, green: 0.68, blue: 0.42, alpha: 1)
        root.addSublayer(ring); root.addSublayer(orbit); orbit.addSublayer(dot)
        resize(geometry)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0; animation.toValue = Double.pi * 2
        animation.duration = 12; animation.repeatCount = .infinity
        animation.beginTime = started
        orbit.add(animation, forKey: "orbit")
        context.layer = root
        CATransaction.flush()
    }
    func resize(_ next: ProbeGeometry) {
        geometry = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: next.size); root.contentsScale = next.scale
        let radius = min(next.size.width, next.size.height) * 0.36
        let center = CGPoint(x: next.size.width / 2, y: next.size.height / 2)
        ring.frame = root.bounds; ring.contentsScale = next.scale
        ring.lineWidth = radius * 0.06
        ring.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        orbit.position = center
        let diameter = radius * 0.3
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.position = CGPoint(x: radius, y: 0); dot.cornerRadius = diameter / 2
        CATransaction.commit()
    }
    func setPaused(_ paused: Bool) {
        if paused, pausedAt == nil {
            pausedAt = CACurrentMediaTime()
            root.timeOffset = root.convertTime(pausedAt!, from: nil); root.speed = 0
        } else if !paused, let previous = pausedAt {
            let offset = root.timeOffset
            root.speed = 1; root.timeOffset = 0; root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - offset
            pausedDuration += CACurrentMediaTime() - previous; pausedAt = nil
        }
    }
    func snapshot() throws -> AnyObject { try ProbeWire.snapshot(snapshotSurface()) }
    func snapshotSurface() throws -> IOSurface {
        let ratio = min(1, 1920 / max(geometry.size.width, geometry.size.height))
        let width = max(1, Int(geometry.size.width * ratio))
        let height = max(1, Int(geometry.size.height * ratio))
        guard let surface = IOSurface(properties: [.width: width, .height: height,
                .bytesPerElement: 4, .pixelFormat: 0x42475241]) else { throw probeError("Snapshot allocation failed") }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let cg = CGContext(data: surface.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw probeError("Snapshot drawing failed")
        }
        let radius = CGFloat(min(width, height)) * 0.36
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        cg.setFillColor(root.backgroundColor!); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.setStrokeColor(ring.strokeColor!); cg.setLineWidth(radius * 0.06)
        cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let angle = elapsed * .pi / 6
        let diameter = radius * 0.3
        cg.setFillColor(dot.backgroundColor!)
        cg.fillEllipse(in: CGRect(x: center.x + radius * cos(angle) - diameter / 2,
            y: center.y + radius * sin(angle) - diameter / 2, width: diameter, height: diameter))
        return surface
    }
    func dispose() {
        root.removeAllAnimations(); orbit.removeAllAnimations(); root.sublayers = nil
        context.layer = nil
        CATransaction.flush()
    }
}

/// Shared across short-lived host connections, with explicit per-ID teardown.
/// Four surfaces maximum (two displays plus settings previews), no media decoder.
final class ProbeSurfaceStore {
    static let shared = ProbeSurfaceStore()
    let queue = DispatchQueue(label: "dev.idlesse.nativeprobe.surfaces")
    private var surfaces: [UUID: ProbeSurface] = [:]
    func acquire(id: UUID, geometry: ProbeGeometry) throws -> AnyObject {
        if let existing = surfaces[id] {
            existing.resize(geometry)
            return try ProbeWire.context(existing.context.contextId)
        }
        guard surfaces.count < 4 else { throw probeError("Surface limit reached") }
        let surface = try ProbeSurface(geometry: geometry)
        let response = try ProbeWire.context(surface.context.contextId)
        surfaces[id] = surface
        extensionLog("Acquired synthetic surface \(surface.context.contextId), active=\(surfaces.count)")
        return response
    }
    func update(id: UUID, request: Any) throws {
        guard let surface = surfaces[id] else { throw probeError("Unknown surface") }
        if probeField("destination", in: request) != nil { surface.resize(try ProbeGeometry(request)) }
        if let state = probeField("activityState", in: request) {
            let active = String(describing: state) == "active"
            surface.setPaused(!active)
            extensionLog("Surface activity: \(state)")
        }
    }
    func snapshot(id: UUID) throws -> AnyObject {
        guard let surface = surfaces[id] else { throw probeError("Unknown snapshot surface") }
        return try surface.snapshot()
    }
    func invalidate(id: UUID) {
        surfaces.removeValue(forKey: id)?.dispose()
        extensionLog("Invalidated synthetic surface, active=\(surfaces.count)")
    }
}
