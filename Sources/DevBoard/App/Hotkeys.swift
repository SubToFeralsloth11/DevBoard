import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts via Carbon hot keys (no Accessibility permission needed).
final class HotkeyCenter {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotkeyCenter.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// `key` is a virtual key code (kVK_*); modifiers default to ⌥⇧.
    func register(_ key: Int, modifiers: Int = optionKey | shiftKey, _ handler: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4442_524B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs.append(ref)
        Self.handlers[id] = handler
    }
}
