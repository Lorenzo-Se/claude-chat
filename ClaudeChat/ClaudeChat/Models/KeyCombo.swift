import AppKit
import HotKey

struct KeyCombo: Codable, Equatable, Hashable {
    var carbonKeyCode: UInt32
    var modifierRawValue: UInt

    init(key: Key, modifiers: NSEvent.ModifierFlags) {
        carbonKeyCode = key.carbonKeyCode
        modifierRawValue = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    var key: Key? {
        Key(carbonKeyCode: carbonKeyCode)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    var displayLabel: String {
        Self.label(for: modifiers, carbonKeyCode: carbonKeyCode)
    }

    static func label(for modifiers: NSEvent.ModifierFlags, carbonKeyCode: UInt32) -> String {
        var parts: [String] = []
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        if let key = Key(carbonKeyCode: carbonKeyCode) {
            parts.append(keyDisplayName(key))
        } else {
            parts.append("?")
        }

        return parts.joined()
    }

    private static func keyDisplayName(_ key: Key) -> String {
        let name = String(describing: key)
        if name.count == 1 {
            return name.uppercased()
        }
        switch name {
        case "return": return "↩"
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "tab": return "⇥"
        case "space": return "Space"
        default: return name.capitalized
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        let required = modifiers.intersection(.deviceIndependentFlagsMask)
        let actual = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return actual == required && event.keyCode == UInt16(carbonKeyCode)
    }
}
