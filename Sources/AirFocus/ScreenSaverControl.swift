import AppKit
import CoreGraphics
import IOKit.ps
import IOKit.pwr_mgt

/// Start the screen saver / lock, and wake to the standard unlock prompt (R§9.1, R§9.2, R§9.5).
/// Never types, stores or automates credentials, and never changes lock settings. Whether a
/// password is required is entirely the user's System Settings › Lock Screen choice.
@MainActor
enum ScreenSaverControl {
    static let engineURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

    /// Public path first (LaunchServices launch of ScreenSaverEngine), private fallback.
    /// UNVERIFIED on macOS 26 hardware that the NSWorkspace launch starts the saver.
    static func start() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: engineURL, configuration: cfg) { app, error in
            if app == nil {
                let status = LoginFramework.screenSaverStartNow?() ?? -1
                Log.error(.lookAway, "ScreenSaverEngine launch failed (\(error?.localizedDescription ?? "nil")); SACScreenSaverStartNow → \(status)")
            } else {
                Log.info(.lookAway, "screen saver launched via NSWorkspace")
            }
        }
    }

    /// Opt-in "Lock immediately (private API)": locks regardless of the password delay.
    static func lockNow() -> Bool {
        guard let lock = LoginFramework.lockScreenImmediate else { return false }
        return lock() == 0
    }

    private static var activityAssertion: IOPMAssertionID = 0

    /// Wake the display and dismiss the screen saver so loginwindow shows its normal password /
    /// Touch ID prompt. No keys are ever posted (an Esc would reach a terminal agent).
    /// Which of the three steps is actually needed on 26.x is UNVERIFIED (R§11.8 item 11).
    static func wakeForUnlock() {
        // 1. Documented: "causes the display to power on". No special privileges needed.
        _ = IOPMAssertionDeclareUserActivity("AirFocus: user looked back" as CFString,
                                             kIOPMUserActiveLocal, &activityAssertion)
        // 2. Screen saver still animating or session locked: ask loginwindow to stop the saver
        //    (private, optional) and nudge with a zero-distance mouse move at the current position.
        if isScreenSaverRunning || isScreenLocked {
            let status = LoginFramework.screenSaverStopNow?() ?? -1
            let here = CGEvent(source: nil)?.location ?? .zero
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: here,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            Log.info(.lookAway, "wake: user activity + SACScreenSaverStopNow (\(status)) + zero-distance mouse move")
        } else {
            Log.info(.lookAway, "wake: user activity only")
        }
    }

    static var isScreenSaverRunning: Bool { LoginFramework.screenSaverIsRunning?().boolValue ?? false }

    /// Public CGSession dictionary; the key is absent when unlocked (BLEUnlock pattern).
    static var isScreenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        return (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    // MARK: Idle-sleep prevention while away (AC power only, spec §2.6)

    private static var sleepAssertion: IOPMAssertionID?

    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    static func preventIdleSleep() {
        guard sleepAssertion == nil, onACPower else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "AirFocus: watching for the user to look back" as CFString, &id)
        if r == kIOReturnSuccess {
            sleepAssertion = id
            Log.info(.lookAway, "holding PreventUserIdleSystemSleep (AC power)")
        }
    }

    static func allowIdleSleep() {
        guard let id = sleepAssertion else { return }
        IOPMAssertionRelease(id)
        sleepAssertion = nil
        Log.info(.lookAway, "released PreventUserIdleSystemSleep")
    }
}

/// "Require password after screen saver begins or display is turned off", read with the public
/// `sysadminctl -screenLock status` (prints to stderr). Read-only: the app never sets it.
enum ScreenLockSetting: Equatable {
    case immediate
    case after(seconds: Int)
    case off
    case unknown(String)

    /// Blocks on a subprocess: call off the main thread.
    nonisolated static func read() -> ScreenLockSetting {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        p.arguments = ["-screenLock", "status"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return .unknown("sysadminctl failed to run") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    nonisolated static func parse(_ out: String) -> ScreenLockSetting {
        if out.contains("delay is immediate") { return .immediate }
        if let r = out.range(of: #"delay is (\d+) seconds"#, options: .regularExpression),
           let n = Int(out[r].split(separator: " ")[2]) {
            return n == 0 ? .immediate : .after(seconds: n)
        }
        // Exact wording of the "off" state is UNVERIFIED (R§9.1); accept the plausible variants.
        let lower = out.lowercased()
        if lower.contains("screenlock is off") || lower.contains("is disabled") || lower.contains("delay is never") {
            return .off
        }
        let line = out.split(separator: "\n").last.map(String.init) ?? out
        return .unknown(line.trimmingCharacters(in: .whitespaces))
    }

    var menuText: String {
        switch self {
        case .immediate: return "locks immediately"
        case .after(let s): return s % 60 == 0 ? "locks after \(s / 60) min" : "locks after \(s) s"
        case .off: return "doesn't lock"
        case .unknown: return "unknown"
        }
    }
}
