import AppKit
import ApplicationServices

/// Accessibility helpers (R§4.2). AX calls can block up to the messaging timeout on a hung app,
/// so everything except the trust checks belongs off the main thread.
enum AX {
    static let messagingTimeout: Float = 0.25

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "would like to control this computer" prompt if not yet trusted.
    @discardableResult
    static func promptForTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMotionSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")
    }

    static func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    static func openLockScreenSettings() {
        open("x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    static func attribute<T>(_ el: AXUIElement, _ name: String, as _: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        // CF types bridge with `as?` only for toll-free types; AXUIElement/AXValue need a type check.
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)   // never hang on a beachballing app
        return app
    }

    static func windows(ofPID pid: pid_t) -> [AXUIElement] {
        guard let list = attribute(application(pid), kAXWindowsAttribute, as: NSArray.self) else { return [] }
        return list.compactMap { item in
            let ref = item as CFTypeRef
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
    }

    /// Exact id via the private `_AXUIElementGetWindow`; nil when unavailable or not a window.
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        guard let fn = AXPrivate.getWindow else { return nil }
        var wid: CGWindowID = 0
        return fn(el, &wid) == .success && wid != 0 ? wid : nil
    }

    static func isWindow(_ el: AXUIElement) -> Bool {
        (attribute(el, kAXRoleAttribute, as: String.self) ?? "") == (kAXWindowRole as String)
    }

    /// AX frames share the CG top-left global space.
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posV = attribute(el, kAXPositionAttribute, as: AXValue.self),
              let sizeV = attribute(el, kAXSizeAttribute, as: AXValue.self) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posV, .cgPoint, &p), AXValueGetValue(sizeV, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// CGWindowID → AXUIElement: exact match first, else the window whose frame matches within 8 pt.
    static func element(forWindow wid: CGWindowID, pid: pid_t, cgFrame: CGRect) -> AXUIElement? {
        let candidates = windows(ofPID: pid).filter(isWindow)
        if AXPrivate.getWindow != nil, let exact = candidates.first(where: { windowID($0) == wid }) { return exact }
        let scored = candidates.compactMap { el -> (AXUIElement, CGFloat)? in
            guard let f = frame(el) else { return nil }
            return (el, frameDistance(f, cgFrame))
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 8 else { return nil }
        return best.0
    }

    static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// The process that currently has keyboard focus, via the system-wide AX element.
    static func focusedApplicationPID() -> pid_t? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, messagingTimeout)
        guard let app = attribute(sys, kAXFocusedApplicationAttribute, as: AXUIElement.self) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success ? pid : nil
    }

    static func focusedWindow(ofPID pid: pid_t) -> AXUIElement? {
        attribute(application(pid), kAXFocusedWindowAttribute, as: AXUIElement.self)
    }
}
