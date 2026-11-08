import AppKit
import AirFocusCore

/// One window in Mission Control: its button in the Dock's Accessibility tree, and where it is on screen.
struct MissionControlThumbnail {
    let element: AXUIElement
    let frame: CGRect
}

/// What a head flick does (spec §2.9).
@MainActor
enum HeadGestures {
    private static let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static let hotkeysDomain = "com.apple.symbolichotkeys" as CFString

    /// Launching the app opens Mission Control, and launching it again closes it.
    static func toggleMissionControl() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: missionControl, configuration: configuration) { _, error in
            if let error { Log.error(.gesture, "couldn't open Mission Control: \(error.localizedDescription)") }
        }
    }

    /// The window thumbnails while Mission Control is open, from the Dock's Accessibility tree:
    /// mc › mc.display › mc.windows › one button per window (checked on 26.7.1). Nothing else in
    /// the tree is ever used: the Desktop buttons beside these have a "remove Desktop" action.
    static func thumbnails() -> [MissionControlThumbnail] {
        guard AX.isTrusted, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }
        let groups = children(of: AX.application(dock.processIdentifier), identifier: "mc")
            .flatMap { children(of: $0, identifier: "mc.display") }
            .flatMap { children(of: $0, identifier: "mc.windows") }
        return groups.flatMap { children(of: $0) }.compactMap { button in
            guard AX.attribute(button, kAXRoleAttribute, as: String.self) == kAXButtonRole, let frame = AX.frame(button)
            else { return nil }
            return MissionControlThumbnail(element: button, frame: frame)
        }
    }

    /// Brings the window forward and closes Mission Control, the same as clicking it, with no mouse involved.
    static func press(_ thumbnail: MissionControlThumbnail) -> Bool {
        AXUIElementPerformAction(thumbnail.element, kAXPressAction as CFString) == .success
    }

    private static func children(of element: AXUIElement, identifier: String? = nil) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.1)     // on the main thread: a busy Dock can't stall tracking
        let all = AX.attribute(element, kAXChildrenAttribute, as: [AXUIElement].self) ?? []
        guard let identifier else { return all }
        return all.filter { AX.attribute($0, kAXIdentifierAttribute, as: String.self) == identifier }
    }

    enum DesktopResult { case moved, shortcutOff, notTrusted, unavailable }

    /// Presses the system's own shortcut. It's read first because, with the shortcut off, the key
    /// press would reach the focused app instead (⌃→ moves a word in a terminal). This is the one
    /// synthetic key press in the app, and it never happens at the lock screen.
    static func moveDesktop(left: Bool) -> DesktopResult {
        guard !ScreenSaverControl.isScreenLocked, !ScreenSaverControl.isScreenSaverRunning else { return .unavailable }
        guard AX.isTrusted else { return .notTrusted }
        CFPreferencesAppSynchronize(hotkeysDomain)
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, hotkeysDomain) as? [String: Any]
        guard let shortcut = DesktopShortcut.resolve(hotkeys, left: left) else { return .shortcutOff }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return .unavailable }
        let flags = CGEventFlags(rawValue: shortcut.eventFlags)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .moved
    }
}
