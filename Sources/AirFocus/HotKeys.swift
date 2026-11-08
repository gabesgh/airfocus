import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey (R§6): still works on macOS 26 and needs no
/// permission. Since macOS 15 a combination must include ⌘ or ⌃ (plain keys registered fine on
/// 26.7.1 in a probe, but the calibration code still keeps a chorded fallback).
/// RegisterEventHotKey does not detect conflicts with system shortcuts.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    struct Token: Hashable { fileprivate let id: UInt32 }

    static let ctrlOptCmd = controlKey | optionKey | cmdKey

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// Returns nil when registration fails (e.g. the system rejects the combination).
    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) -> Token? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4146_4F43), id: id)   // 'AFOC'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error(.hotkeys, "RegisterEventHotKey(key \(keyCode), mods \(modifiers)) failed: \(status)")
            return nil
        }
        refs[id] = ref
        actions[id] = action
        return Token(id: id)
    }

    func unregister(_ token: Token?) {
        guard let token, let ref = refs.removeValue(forKey: token.id) else { return }
        UnregisterEventHotKey(ref)
        actions.removeValue(forKey: token.id)
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// For --diagnose: can plain (unmodified) Esc/Return be registered on this system?
    /// Registers and immediately unregisters; nothing is left behind.
    static func probePlainKeys() -> Bool {
        var ok = true
        for code in [kVK_Escape, kVK_Return] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: OSType(0x4146_5052), id: 99),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { ok = false }
            if let ref { UnregisterEventHotKey(ref) }
        }
        return ok
    }
}
