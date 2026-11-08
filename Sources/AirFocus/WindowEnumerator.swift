import AppKit
import CoreGraphics
import AirFocusCore

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Screen geometry in CG space. NSScreen.screens is never cached: it changes with the arrangement.
enum Screens {
    /// Height of the primary display (the one with the menu bar, NSScreen.screens[0]).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static var framesCG: [CGRect] {
        let h = primaryHeight
        return NSScreen.screens.map { Geometry.cgRect(fromAppKit: $0.frame, primaryHeight: h) }
    }

    static var configuration: DisplayConfiguration {
        let h = primaryHeight
        return DisplayConfiguration(displays: NSScreen.screens.map { s in
            let id = s.displayID
            return DisplayInfo(id: id, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                               serial: CGDisplaySerialNumber(id),
                               frameCG: Geometry.cgRect(fromAppKit: s.frame, primaryHeight: h))
        })
    }

    /// The main screen's centre in CG space (mouse simulation pivots around it).
    static var primaryCentreCG: CGPoint {
        guard let f = framesCG.first else { return .zero }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// True when Stage Manager is on (it re-lays windows out when focus changes, R§3.4).
    static var stageManagerEnabled: Bool {
        (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
    }
}

/// Enumerates on-screen windows with CGWindowListCopyWindowInfo (no Screen Recording needed for
/// bounds/PID/layer/alpha/order, R§3.2) and filters them with WindowFilter.
final class WindowEnumerator {
    private var appCache: [pid_t: WindowFilter.AppInfo] = [:]
    private var cacheAge = 0
    /// True while Settings is open: its window and colour panel then cover what's behind them.
    var ownWindowsOcclude = false

    func snapshot() -> WindowFilterResult {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        // NSRunningApplication lookups are cached briefly; PIDs are not reused that quickly.
        cacheAge += 1
        if cacheAge > 40 { appCache.removeAll(); cacheAge = 0 }
        return WindowFilter.filter(raw, ownPID: ProcessInfo.processInfo.processIdentifier,
                                   screensCG: Screens.framesCG, ownWindowsOcclude: ownWindowsOcclude,
                                   appInfo: { [self] pid in
            if let cached = appCache[pid] { return cached }
            let app = NSRunningApplication(processIdentifier: pid)
            let info = app.map { WindowFilter.AppInfo(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
            if let info { appCache[pid] = info }
            return info
        })
    }
}

/// Polls the window list at 8 Hz, only while tracking or calibrating (spec §3.5).
@MainActor
final class WindowPoller {
    static let interval: TimeInterval = 1.0 / 8.0

    private let enumerator = WindowEnumerator()
    private var timer: Timer?
    private(set) var windows: [TrackedWindow] = []
    private(set) var missionControlOpen = false
    var onUpdate: (([TrackedWindow]) -> Void)?

    var isRunning: Bool { timer != nil }

    var ownWindowsOcclude: Bool {
        get { enumerator.ownWindowsOcclude }
        set { enumerator.ownWindowsOcclude = newValue }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.debug(.windows, "window poll started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func refresh() -> [TrackedWindow] {
        let snapshot = enumerator.snapshot()
        windows = snapshot.windows
        missionControlOpen = snapshot.missionControlOpen
        onUpdate?(windows)
        return windows
    }
}
