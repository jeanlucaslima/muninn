import Carbon
import Foundation

// Global callback storage — accessed only from main thread via Carbon event handler
nonisolated(unsafe) private var hotKeyHandler: (() -> Void)?

final class HotKeyManager: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?

    func register(handler: @escaping () -> Void) {
        hotKeyHandler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                hotKeyHandler?()
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        // Cmd+Option+V: keycode 9 (V), modifiers cmdKey | optionKey
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4D554E4E), // "MUNN"
            id: 1
        )

        let modifiers = UInt32(cmdKey | optionKey)

        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        hotKeyHandler = nil
    }

    deinit {
        unregister()
    }
}
