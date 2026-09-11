import AppKit
import Carbon

/// System-wide wallpaper hotkeys that need no Accessibility permission:
/// Ctrl+Opt+Cmd+Right/Left steps through the Library, Ctrl+Opt+Cmd+Space
/// toggles pause. Carbon hotkeys fire regardless of which app is focused.
final class HotKeysController {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onTogglePause: (() -> Void)?

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyBridge, 1, &spec, selfPtr, &handler) == noErr else { return }
        register(keyCode: UInt32(kVK_RightArrow), id: 1)
        register(keyCode: UInt32(kVK_LeftArrow), id: 2)
        register(keyCode: UInt32(kVK_Space), id: 3)
    }

    private func register(keyCode: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        var hotID = EventHotKeyID(signature: OSType(0x49534C45), id: id) // 'ISLE'
        let mods = UInt32(cmdKey | controlKey | optionKey)
        guard RegisterEventHotKey(keyCode, mods, hotID, GetApplicationEventTarget(), 0, &ref) == noErr else { return }
        refs.append(ref)
    }

    fileprivate func pressed(id: UInt32) {
        switch id {
        case 1: onNext?()
        case 2: onPrevious?()
        case 3: onTogglePause?()
        default: break
        }
    }

    func stop() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit { stop() }
}

private func hotKeyBridge(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var hotID = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotID) == noErr else { return noErr }
    let controller = Unmanaged<HotKeysController>.fromOpaque(data!).takeUnretainedValue()
    DispatchQueue.main.async { controller.pressed(id: hotID.id) }
    return noErr
}
