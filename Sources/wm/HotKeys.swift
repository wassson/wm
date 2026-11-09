import Carbon.HIToolbox
import WMCore

/// Global hotkeys via Carbon's RegisterEventHotKey. Unlike an event tap this needs no
/// Input Monitoring permission, and the key press is consumed (not passed to the app).
@MainActor
final class HotKeyCenter {
    var handler: ((Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature = OSType(0x574D_484B)  // 'WMHK'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            MainActor.assumeIsolated { center.fire(id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Replaces all registered hotkeys. Returns descriptions of chords that couldn't
    /// be registered (usually because another app already owns them).
    @discardableResult
    func register(_ bindings: [KeyBinding]) -> [String] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()

        var failures: [String] = []
        for (index, binding) in bindings.enumerated() {
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.chord.keyCode, carbonModifiers(binding.chord.modifiers),
                                             id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = binding.action
            } else {
                failures.append("\(binding.action) (status \(status))")
            }
        }
        return failures
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        handler?(action)
    }

    private func carbonModifiers(_ m: Modifiers) -> UInt32 {
        var flags = 0
        if m.contains(.command) { flags |= cmdKey }
        if m.contains(.option) { flags |= optionKey }
        if m.contains(.control) { flags |= controlKey }
        if m.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}
