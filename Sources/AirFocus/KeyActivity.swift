import AppKit
import CoreGraphics
import AirFocusCore

/// Typing-guard input (spec §2.4): a global `.keyDown` monitor that records timestamps only.
/// Never looks at which key was pressed. The monitor needs Accessibility; until it is granted,
/// CGEventSource's public "seconds since last keyDown" fills in (no permission needed).
@MainActor
final class KeyActivity {
    private var monitor: Any?
    private var monitorTrusted = false
    private(set) var lastMonitoredKeyDown: TimeInterval = -.infinity
    /// Called on every keyDown with its uptime timestamp (implicit recentring hook).
    var onKeyDown: ((TimeInterval) -> Void)?

    func start() {
        // A monitor installed before the Accessibility grant may stay deaf; reinstall on trust change.
        let trusted = AX.isTrusted
        if monitor != nil, trusted == monitorTrusted { return }
        stop()
        monitorTrusted = trusted
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let t = event.timestamp
            MainActor.assumeIsolated {
                self?.lastMonitoredKeyDown = t
                self?.onKeyDown?(t)
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Uptime of the most recent keyDown from either source.
    var lastKeyDown: TimeInterval {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return max(lastMonitoredKeyDown, ProcessInfo.processInfo.systemUptime - idle)
    }

    /// Seconds since any keyboard, mouse or trackpad event (look-away veto; public, no permission).
    static var secondsSinceUserInput: TimeInterval {
        // kCGAnyInputEventType is ~0; the imported enum accepts the raw value (checked on 26.7.1).
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}

/// Session traces' clicks (spec §2.10): a global left/right mouse-down monitor, installed only while
/// tracking. It records where and when, never what was clicked on. Global mouse monitors need no
/// permission, and they don't see clicks in our own windows.
@MainActor
final class MouseActivity {
    private var monitor: Any?
    /// Uptime timestamp, CG-space position, and whether it was the right button.
    var onMouseDown: ((TimeInterval, CGPoint, Bool) -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let t = event.timestamp
            let right = event.type == .rightMouseDown
            // CGEvent locations are already global CG space (top-left origin).
            let p = event.cgEvent?.location
                ?? Geometry.cgPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: Screens.primaryHeight)
            MainActor.assumeIsolated { self?.onMouseDown?(t, p, right) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
