import Carbon.HIToolbox
import Foundation

/// System-wide hotkey through Carbon's RegisterEventHotKey: no permission prompt, no dependency.
@MainActor
public final class GlobalHotKey {
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// `keyCode` is a virtual key code (`kVK_ANSI_V`), `modifiers` Carbon flags (`controlKey | optionKey`).
    public init?(keyCode: Int, modifiers: Int, handler: @escaping @MainActor () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4352_5453), id: id) // 'CRTS'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        reference = ref
        Self.handlers[id] = handler
    }

    public func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    fileprivate static func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
    }
}

private func hotKeyCallback(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GlobalHotKey.fire(id) }
    }
    return noErr
}
