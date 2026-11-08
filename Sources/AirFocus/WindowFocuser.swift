import AppKit
import ApplicationServices
import AirFocusCore

/// Focuses a specific window of another app from a background agent (R§4.4, spec §2.5).
///
/// Public activation is only "a request" since macOS 14 and a head-tracking agent never has an
/// activation context to yield, so the primary path is the private SkyLight sequence AltTab and
/// yabai use. Never posts keystrokes, and the only synthetic "click" is the off-window make-key
/// record (see SkyLight.makeKeyWindow), which cannot land in window content.
final class WindowFocuser: @unchecked Sendable {
    enum Path: String { case skyLight = "SkyLight", fallback = "public AX fallback" }

    struct Result {
        let windowID: CGWindowID
        let pid: pid_t
        let appName: String
        let path: Path
        let verified: Bool
        let retried: Bool
    }

    /// Called on the main queue after verification.
    var onResult: ((Result) -> Void)?

    private let queue = DispatchQueue(label: "com.gshimoon.airfocus.focus", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    private func isLatest(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    /// Enqueue a focus request; a newer request supersedes any not yet performed.
    func focus(_ w: TrackedWindow, reason: String) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let target = (id: w.id, pid: w.pid, frame: w.frameCG, app: w.appName)
        Log.info(.focus, "request \(reason): \(target.app) wid \(target.id)")
        queue.async { [self] in
            guard isLatest(gen) else { return Log.debug(.focus, "dropped stale request wid \(target.id)") }
            let ax = AX.element(forWindow: target.id, pid: target.pid, cgFrame: target.frame)
            let path = perform(wid: target.id, pid: target.pid, axWindow: ax)
            // AltTab #6064: all steps can report success and still leave the previous window on top.
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
                guard isLatest(gen) else { return }
                var ok = check(wid: target.id, pid: target.pid, frame: target.frame)
                var retried = false
                if !ok {
                    retried = true
                    if let ax { AXUIElementPerformAction(ax, kAXRaiseAction as CFString) }
                    if AX.focusedApplicationPID() != target.pid { publicFallback(axWindow: ax, pid: target.pid) }
                    usleep(150_000)
                    ok = check(wid: target.id, pid: target.pid, frame: target.frame)
                }
                let result = Result(windowID: target.id, pid: target.pid, appName: target.app, path: path,
                                    verified: ok, retried: retried)
                if ok {
                    Log.info(.focus, "focused \(target.app) wid \(target.id) via \(path.rawValue)\(retried ? " after re-raise" : "")")
                } else {
                    Log.error(.focus, "verify mismatch: \(target.app) wid \(target.id) not frontmost/focused after \(path.rawValue)")
                }
                DispatchQueue.main.async { [weak self] in self?.onResult?(result) }
            }
        }
    }

    private func perform(wid: CGWindowID, pid: pid_t, axWindow: AXUIElement?) -> Path {
        if let setFront = SkyLight.setFrontProcess, var psn = CarbonProcess.psn(for: pid) {
            let err = setFront(&psn, wid, SkyLight.kCPSUserGenerated)            // 1. front process, only this window
            let keyed = SkyLight.makeKeyWindow(&psn, wid)                         // 2. keyboard focus
            if let w = axWindow { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }   // 3. raise in app
            if err != .success || !keyed {
                Log.error(.focus, "SkyLight returned \(err.rawValue), make-key \(keyed); adding public fallback")
                publicFallback(axWindow: axWindow, pid: pid)
            }
            return .skyLight
        }
        publicFallback(axWindow: axWindow, pid: pid)
        return .fallback
    }

    /// Public-API path (Napoleon / mac-taskbar style). Whether it works with no user input to
    /// our process is UNVERIFIED (R§4.1); Chrome-like apps ignore AX writes while inactive.
    private func publicFallback(axWindow: AXUIElement?, pid: pid_t) {
        if let w = axWindow {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(AX.application(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])   // advisory since 14
    }

    /// Frontmost app and its focused window match the target.
    private func check(wid: CGWindowID, pid: pid_t, frame: CGRect) -> Bool {
        let frontPID = AX.focusedApplicationPID() ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontPID == pid else { return false }
        guard let focused = AX.focusedWindow(ofPID: pid) else { return false }
        if let id = AX.windowID(focused) { return id == wid }
        if let f = AX.frame(focused) { return AX.frameDistance(f, frame) < 8 }
        return false
    }
}
