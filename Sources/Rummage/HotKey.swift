import Carbon
import Foundation

struct HotKeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let all: [HotKeyPreset] = [
        HotKeyPreset(title: "⌥⌘F", keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | optionKey)),
        HotKeyPreset(title: "⇧⌘F", keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey)),
        HotKeyPreset(title: "⌃⌥F", keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(title: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(title: "⌘F", keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey)),
    ]
}

/// Global hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    static var action: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    var isRegistered: Bool { ref != nil }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ preset: HotKeyPreset) {
        unregister()
        HotKey.installHandler()
        let id = EventHotKeyID(signature: OSType(0x4646_4E44), id: 1) // 'FFND'
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
