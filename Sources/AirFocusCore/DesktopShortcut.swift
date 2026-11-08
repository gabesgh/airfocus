import Foundation

/// The system's "Move left a space" and "Move right a space" shortcuts, as stored under
/// AppleSymbolicHotKeys in com.apple.symbolichotkeys. No public API moves between Desktops, so a
/// sideways flick presses whatever these are set to.
public struct DesktopShortcut: Equatable, Sendable {
    public var keyCode: UInt16
    /// CGEventFlags, raw. The default is control + fn.
    public var modifiers: UInt64

    static let controlFn: UInt64 = 0x840000
    static let numericPad: UInt64 = 0x200000
    static let arrowKeys: ClosedRange<UInt16> = 123...126
    static let noKey = 65535

    /// What to post. A real arrow key also carries the numeric pad flag, but the stored modifiers
    /// leave it out, and the key press only moved the Desktop with it (checked on 26.7.1).
    public var eventFlags: UInt64 {
        Self.arrowKeys.contains(keyCode) ? modifiers | Self.numericPad : modifiers
    }

    /// nil when the shortcut is off or isn't a key press: posting then would only reach the focused
    /// app. An entry with no stored key uses the system default, as macOS does.
    public static func resolve(_ hotkeys: [String: Any]?, left: Bool) -> DesktopShortcut? {
        let standard = DesktopShortcut(keyCode: left ? 123 : 124, modifiers: controlFn)
        guard let entry = hotkeys?[left ? "79" : "81"] as? [String: Any] else { return standard }
        if let enabled = entry["enabled"] as? NSNumber, !enabled.boolValue { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return standard }
        guard parameters[1].intValue != noKey, let key = UInt16(exactly: parameters[1].intValue) else { return nil }
        return DesktopShortcut(keyCode: key, modifiers: parameters[2].uint64Value)
    }
}
