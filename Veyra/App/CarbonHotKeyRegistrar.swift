import AppKit
import Carbon

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private var eventHandler: EventHandlerRef?
    private var nextID = 0
    private var registrations: [Int: (EventHotKeyRef, @MainActor (HotKeyEvent) -> Void)] = [:]
    private static let signature: OSType = 0x56595241 // VYRA

    func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor (HotKeyEvent) -> Void) throws -> Int {
        if eventHandler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                // Application event handlers are delivered on the AppKit main thread.
                return MainActor.assumeIsolated {
                    Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue().receive(event)
                }
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { throw HotKeyFailure(status: status) }
        }
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.carbonFlags,
                                        EventHotKeyID(signature: Self.signature, id: UInt32(nextID)),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw HotKeyFailure(status: status) }
        registrations[nextID] = (reference, handler)
        return nextID
    }

    func unregister(_ token: Int) {
        if let registration = registrations.removeValue(forKey: token) { UnregisterEventHotKey(registration.0) }
        if registrations.isEmpty, let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == Self.signature,
              let registration = registrations[Int(identifier.id)] else { return OSStatus(eventNotHandledErr) }
        registration.1(GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .pressed : .released)
        return noErr
    }

    isolated deinit {
        for (_, registration) in registrations { UnregisterEventHotKey(registration.0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: Self = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.shift) { value.insert(.shift) }
        self = value
    }

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

extension GlobalShortcut {
    /// Resolve the saved physical key using the current keyboard layout, not input text.
    @MainActor var displayName: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        let special: [UInt32: String] = [36: "↩", 48: "⇥", 49: L10n.text("Space"), 51: "⌫", 53: "⎋",
            64: "F17", 65: ".", 67: "*", 69: "+", 71: "⌧", 75: "/", 76: "⌤", 78: "−", 79: "F18", 80: "F19",
            81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
            106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "↖",
            116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = special[keyCode] { return prefix + name }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKey: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                            &deadKey, characters.count, &length, &characters)
                if status == noErr, length > 0 {
                    return prefix + String(utf16CodeUnits: characters, count: length).uppercased()
                }
            }
        }
        return prefix + L10n.text("Key \(keyCode)")
    }
}
