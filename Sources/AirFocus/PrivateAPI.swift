import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// Every private (or Swift-unavailable) symbol is resolved at runtime with dlsym, so a missing
// symbol degrades to a public fallback instead of failing at load (spec §3.5, R§4.3).
// Resolution was checked on macOS 26.7.1 (R§10); behaviour on hardware is UNVERIFIED.

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
    guard let handle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

/// Images already loaded into the process (we link ApplicationServices, which carries HIServices).
private let processHandle = dlopen(nil, RTLD_LAZY)

/// Window server calls used by AltTab/yabai to focus a specific window from a background agent.
enum SkyLight {
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    /// kCPSUserGenerated: bring only this window forward (0x100 = all windows, 0x400 = none).
    static let kCPSUserGenerated: UInt32 = 0x200

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let setFrontProcess = symbol(handle, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    static let postEventRecord = symbol(handle, "SLPSPostEventRecordTo", as: PostEventRecordFn.self)

    /// Make `wid` the key window of its process with a synthetic window-server event record.
    /// Layout follows AltTab on macOS 26 (R§4.3):
    ///  - 0x100-byte zeroed buffer: macOS 14.7.4+ reads past a 0xf8 record and would SIGABRT;
    ///  - mouse-down only (no up): "the down alone makes the right window key" (macOS 26.5);
    ///  - click point (300000, 300000): far off every window. NaN gets sanitised to (0,0) by some
    ///    apps and would click real content (a terminal's first pane), and a point just off the
    ///    frame hits the resize region. This record never reaches window content.
    static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) -> Bool {
        guard let post = postEventRecord else { return false }
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8                  // record length
        bytes[0x08] = 0x01                  // kCGEventLeftMouseDown
        bytes[0x3a] = 0x10                  // undocumented flag (yabai/Hammerspoon)
        var w = wid
        withUnsafeBytes(of: &w) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        var pt = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &pt) { bytes.replaceSubrange(0x20..<0x30, with: $0) }
        var err = CGError.failure
        bytes.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress { err = post(&psn, base) }
        }
        return err == .success
    }
}

/// Deprecated Carbon process calls: still exported, but marked unavailable in Swift.
enum CarbonProcess {
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    static let getProcessForPID = symbol(processHandle, "GetProcessForPID", as: GetProcessForPIDFn.self)

    static func psn(for pid: pid_t) -> ProcessSerialNumber? {
        guard let fn = getProcessForPID else { return nil }
        var psn = ProcessSerialNumber()
        return fn(pid, &psn) == noErr ? psn : nil
    }
}

/// `_AXUIElementGetWindow`: AXUIElement → CGWindowID (exported by HIServices, used by AltTab,
/// Rectangle, yabai). Answers with the containing window's id for descendants, so callers
/// must check the element's role first.
enum AXPrivate {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let getWindow = symbol(processHandle, "_AXUIElementGetWindow", as: GetWindowFn.self)
}

/// Private login.framework entry points (signatures from Chromium's base/mac/login_util.cc).
enum LoginFramework {
    typealias StatusFn = @convention(c) () -> OSStatus
    typealias BoolFn = @convention(c) () -> DarwinBoolean

    private static let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY)
    static let screenSaverStartNow = symbol(handle, "SACScreenSaverStartNow", as: StatusFn.self)
    static let screenSaverStopNow = symbol(handle, "SACScreenSaverStopNow", as: StatusFn.self)
    static let screenSaverIsRunning = symbol(handle, "SACScreenSaverIsRunning", as: BoolFn.self)
    static let screenLockEnabled = symbol(handle, "SACScreenLockEnabled", as: BoolFn.self)
    static let lockScreenImmediate = symbol(handle, "SACLockScreenImmediate", as: StatusFn.self)
}

enum PrivateAPI {
    /// For --diagnose: which symbols resolved on this system.
    static var report: [(name: String, resolved: Bool)] {
        [
            ("SkyLight _SLPSSetFrontProcessWithOptions", SkyLight.setFrontProcess != nil),
            ("SkyLight SLPSPostEventRecordTo", SkyLight.postEventRecord != nil),
            ("HIServices _AXUIElementGetWindow", AXPrivate.getWindow != nil),
            ("HIServices GetProcessForPID", CarbonProcess.getProcessForPID != nil),
            ("login SACScreenSaverStartNow", LoginFramework.screenSaverStartNow != nil),
            ("login SACScreenSaverStopNow", LoginFramework.screenSaverStopNow != nil),
            ("login SACScreenSaverIsRunning", LoginFramework.screenSaverIsRunning != nil),
            ("login SACScreenLockEnabled", LoginFramework.screenLockEnabled != nil),
            ("login SACLockScreenImmediate", LoginFramework.lockScreenImmediate != nil),
        ]
    }
}
