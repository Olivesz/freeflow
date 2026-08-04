import AppKit
import Carbon.HIToolbox

/// A global hotkey via Carbon RegisterEventHotKey — needs NO Input Monitoring
/// permission. Fires `onDown` on press and `onUp` on release, so it can drive
/// both tap-to-toggle and hold-to-talk. Rebindable via `register(...)`.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let this = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed):  me.onDown()
            case UInt32(kEventHotKeyReleased): me.onUp()
            default: break
            }
            return noErr
        }, 2, &specs, this, &handlerRef)
    }

    /// (Re)bind to a key + modifier combo. Safe to call repeatedly.
    func register(keyCode: UInt32, modifiers: UInt32) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let id = EventHotKeyID(signature: OSType(0x46464C57), id: 1)  // 'FFLW'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
