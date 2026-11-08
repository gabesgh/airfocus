import AppKit
import Observation
import ServiceManagement
import SwiftUI
import AirFocusCore

/// What the Settings window asks of the app. The CLI's offscreen render supplies a fake one, so
/// rendering never touches the real pipeline or the app's preferences.
@MainActor
protocol SettingsBackend: AnyObject {
    var settings: AppSettings { get }
    func settingsChanged()
    func settingsStatus() -> SettingsStatus
    /// Separate from the status above because it is a round trip to a system daemon: read when the
    /// window opens, after a change, and when the app becomes active again.
    func launchAtLoginState() -> LaunchAtLoginState
    /// The window opened or closed: while open it counts as covering the windows behind it.
    func settingsWindowOpenChanged(_ open: Bool)
    /// The window or its colour panel became or stopped being key.
    func settingsKeyChanged(_ key: Bool)
    func calibrate()
    func resetAndRecalibrate()
    func recenterFromSettings()
    func setLaunchAtLogin(_ on: Bool)
    func openLoginItemsSettings()
    func openLockScreenSettings()
}

/// The General section's status row and the things that enable controls. Sampled at most twice a
/// second while the window is open, never at the sample rate.
struct SettingsStatus: Equatable {
    var tracking = "Off"
    var airPods = "not connected"
    var sampleRate = "no samples"
    var calibration = "not calibrated"
    var hasCalibration = false
    var canRecenter = false
    var lookAwayBlockReason: String?
    var screenLock = "not read yet"
}

struct LaunchAtLoginState: Equatable {
    var enabled = false
    var needsApproval = false
}

/// Bindings onto AppSettings, which stays the only store. `revision` is what SwiftUI observes: every
/// write bumps it, applies the change live and has already persisted it.
@MainActor
@Observable
final class SettingsModel {
    @ObservationIgnored let backend: SettingsBackend
    @ObservationIgnored private var settings: AppSettings { backend.settings }
    /// Sections read this in their bodies, so every binding is re-read after any write.
    private(set) var revision = 0

    var section: SettingsSection = .tracking {
        didSet { if section != oldValue { onSectionChange?(section) } }
    }
    @ObservationIgnored var onSectionChange: ((SettingsSection) -> Void)?
    private(set) var status: SettingsStatus
    private(set) var launchState: LaunchAtLoginState
    /// For the offscreen render of the accessibility variants; the live window reads the system.
    @ObservationIgnored var forcedVisual = SettingsVisual()

    init(backend: SettingsBackend) {
        self.backend = backend
        status = backend.settingsStatus()
        launchState = backend.launchAtLoginState()
    }

    func refreshStatus() {
        let new = backend.settingsStatus()
        if new != status { status = new }
    }

    func refreshLaunchState() {
        let new = backend.launchAtLoginState()
        if new != launchState { launchState = new }
    }

    func binding<T>(_ path: ReferenceWritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { [self] in
            _ = revision
            return settings[keyPath: path]
        }, set: { [self] new in
            settings[keyPath: path] = new
            changed()
        })
    }

    /// Writes snapped to `step`, so a slider lands on exact values.
    func stepped(_ path: ReferenceWritableKeyPath<AppSettings, Double>, step: Double) -> Binding<Double> {
        let plain = binding(path)
        return Binding(get: { plain.wrappedValue }, set: { new in
            let snapped = (new / step).rounded() * step
            if snapped != plain.wrappedValue { plain.wrappedValue = snapped }
        })
    }

    var sensitivity: Binding<Double> {
        let plain = binding(\.sensitivity)
        return Binding(get: { plain.wrappedValue }, set: { new in
            let snapped = SensitivityTuning.snapped(new)
            if snapped != plain.wrappedValue { plain.wrappedValue = snapped }
        })
    }

    var appearance: OverlayAppearance {
        _ = revision
        return settings.overlayAppearance
    }

    var tuning: SensitivityTuning {
        _ = revision
        return settings.tuning
    }

    var launchAtLogin: Binding<Bool> {
        Binding(get: { [self] in launchState.enabled || launchState.needsApproval }, set: { [self] on in
            backend.setLaunchAtLogin(on)
            refreshLaunchState()
        })
    }

    func restoreDefaults() {
        settings.restoreAppearanceAndSensitivity()
        changed()
    }

    /// Something outside the window (the menu) changed a setting: show it.
    func reload() { revision += 1 }

    private func changed() {
        revision += 1
        backend.settingsChanged()
    }
}

/// Owns the Settings window (spec §2.8). Created lazily; the window, its hosting view, the model and
/// the status timer exist only while it is open, so a closed window costs nothing.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let contentWidth: CGFloat = 560

    private let backend: SettingsBackend
    private var window: NSWindow?
    private var model: SettingsModel?
    private var statusTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?

    init(backend: SettingsBackend) {
        self.backend = backend
    }

    var isOpen: Bool { window != nil }

    /// A setting changed from the menu while the window may be open.
    func settingsChangedElsewhere() { model?.reload() }

    func show() {
        if let window {
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        let window = makeWindow()
        NSApp.mainMenu = makeMainMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Activation is only a request since macOS 14: show the window even if it is declined.
        window.orderFrontRegardless()
        startObserving()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.refreshStatus() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)       // keeps refreshing during a slider drag
        statusTimer = timer
        backend.settingsWindowOpenChanged(true)
        Log.info(.app, "settings window opened")
    }

    /// Returns whether a window was open.
    @discardableResult
    func closeIfOpen() -> Bool {
        guard let window else { return false }
        window.close()
        return true
    }

    /// Built without showing anything, so the CLI can render the same window offscreen.
    func makeWindow(section: SettingsSection = .tracking, visual: SettingsVisual = SettingsVisual()) -> NSWindow {
        let model = SettingsModel(backend: backend)
        model.section = section
        model.forcedVisual = visual
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: section.height),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "AirFocus Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let hosting = NSHostingView(rootView: SettingsRootView(model: model))
        hosting.sizingOptions = []          // the window sets the size, per section
        window.contentView = hosting
        model.onSectionChange = { [weak self] section in
            // Next pass: not in the middle of SwiftUI's update.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(section) } }
        }
        self.window = window
        self.model = model
        return window
    }

    /// Grows or shrinks downwards, keeping the title bar where the user put it.
    private func fit(_ section: SettingsSection) {
        guard let window else { return }
        let height = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: section.height)).height
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Run-loop deferred so the window isn't freed in the middle of its own close.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        statusTimer?.invalidate()
        statusTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // `sharedColorPanelExists`: asking for NSColorPanel.shared would create one just to close it.
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        backend.settingsKeyChanged(false)
        backend.settingsWindowOpenChanged(false)
        restoreAccessoryPolicy()
        previousApp = nil
        closing.delegate = nil
        window = nil
        model = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated { closing.contentView = nil }
        }
        Log.info(.app, "settings window closed")
    }

    /// Back to a menu bar agent, handing focus to whatever had it unless the user already moved on.
    private func restoreAccessoryPolicy() {
        let wasActive = NSApp.isActive
        NSApp.mainMenu = nil
        NSApp.setActivationPolicy(.accessory)
        guard wasActive else { return }
        if let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        } else {
            NSApp.deactivate()
        }
    }

    /// Any of our windows being key holds automatic switching, the colour panel included: clicking
    /// into it must not hand the head tracker control of focus. Overlay panels can't become key.
    private func startObserving() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Next pass: during a hand-over the old window has resigned and the new one isn't key yet.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateKeyState() } }
            })
        }
        // The user may have just approved the login item in System Settings.
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.refreshLaunchState() }
        })
        updateKeyState()
    }

    private func updateKeyState() {
        guard window != nil else { return }
        backend.settingsKeyChanged(NSApp.isActive && NSApp.keyWindow != nil)
    }

    /// `.regular` shows a menu bar, and without these ⌘W, ⌘Q and paste in the colour panel do nothing.
    private func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        func top(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            parent.submenu = sub
            return parent
        }
        let main = NSMenu()
        main.addItem(top("AirFocus", [
            item("About AirFocus", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            ClosureMenuItem("Settings…", key: ",", modifiers: .command) { [weak self] in self?.show() },
            .separator(),
            item("Hide AirFocus", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit AirFocus", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(top("File", [item("Close", #selector(NSWindow.performClose(_:)), "w")]))
        main.addItem(top("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(top("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")]))
        return main
    }
}

extension AppController: SettingsBackend {
    func settingsStatus() -> SettingsStatus {
        var s = SettingsStatus()
        if isCalibrating {
            s.tracking = "Calibrating"
        } else if !trackingEnabled {
            s.tracking = "Off: start it from the menu or with ⌃⌥⌘T"
        } else {
            s.tracking = switchingPaused ? "On, switching paused until you recenter" : "On"
        }
        s.airPods = airPodsStatus(includeRate: false).text.replacingOccurrences(of: "AirPods: ", with: "")
        s.sampleRate = source.isRunning && isStreaming ? String(format: "%.0f Hz", source.sampleRate) : "no samples"
        if let calibration {
            s.calibration = "\(calibration.summary), \(calibration.qualityLabel)"
        }
        s.hasCalibration = calibration != nil
        s.canRecenter = calibration != nil && trackingEnabled
        s.lookAwayBlockReason = lookAwayBlockReason
        s.screenLock = screenLock.menuText
        return s
    }

    func launchAtLoginState() -> LaunchAtLoginState {
        let status = SMAppService.mainApp.status
        return LaunchAtLoginState(enabled: status == .enabled, needsApproval: status == .requiresApproval)
    }

    func settingsWindowOpenChanged(_ open: Bool) {
        poller.ownWindowsOcclude = open
        if open { refreshScreenLock() }
        if poller.isRunning { poller.refresh() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                Log.info(.app, "launch at login enabled (status \(service.status.rawValue))")
            } else {
                try service.unregister()
                Log.info(.app, "launch at login disabled")
            }
        } catch {
            Log.error(.app, "launch at login: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Launch at Login failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
    func openLockScreenSettings() { AX.openLockScreenSettings() }
}
