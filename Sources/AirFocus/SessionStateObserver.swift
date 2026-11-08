import AppKit

/// Screen saver, lock and display-sleep state (R§9.3, R§9.5). The distributed notification names
/// are undocumented but used by Chromium's idle_mac.mm, BLEUnlock and Dorso.
@MainActor
final class SessionStateObserver {
    private(set) var screenSaverRunning = false
    private(set) var screenLocked = false
    private(set) var displayAsleep = false
    var onChange: (() -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    /// The overlay is hidden and focusing paused whenever this is true.
    var isObscured: Bool { screenSaverRunning || screenLocked }

    init() {
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        add(dnc, "com.apple.screensaver.didstart", "screen saver started") { $0.screenSaverRunning = true }
        add(dnc, "com.apple.screensaver.didstop", "screen saver stopped") { $0.screenSaverRunning = false }
        add(dnc, "com.apple.screenIsLocked", "screen locked") { $0.screenLocked = true }
        add(dnc, "com.apple.screenIsUnlocked", "screen unlocked") { $0.screenLocked = false }
        add(wnc, NSWorkspace.screensDidSleepNotification.rawValue, "displays slept") { $0.displayAsleep = true }
        add(wnc, NSWorkspace.screensDidWakeNotification.rawValue, "displays woke") { $0.displayAsleep = false }
        add(wnc, NSWorkspace.willSleepNotification.rawValue, "system will sleep") { _ in }
        add(wnc, NSWorkspace.didWakeNotification.rawValue, "system woke") { _ in }
        screenLocked = ScreenSaverControl.isScreenLocked
        screenSaverRunning = ScreenSaverControl.isScreenSaverRunning
    }

    /// Re-read the pollable state (public CGSession dictionary, private SAC query).
    func poll() {
        let locked = ScreenSaverControl.isScreenLocked
        let saver = ScreenSaverControl.isScreenSaverRunning
        guard locked != screenLocked || saver != screenSaverRunning else { return }
        screenLocked = locked
        screenSaverRunning = saver
        Log.info(.session, "polled state: locked \(locked), screen saver \(saver)")
        onChange?()
    }

    private func add(_ nc: NotificationCenter, _ name: String, _ label: String,
                     _ apply: @escaping (SessionStateObserver) -> Void) {
        let t = nc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.info(.session, label)
                apply(self)
                self.onChange?()
            }
        }
        tokens.append((nc, t))
    }

    func invalidate() {
        tokens.forEach { $0.0.removeObserver($0.1) }
        tokens.removeAll()
    }
}
