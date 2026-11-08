import AppKit
import AirFocusCore

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], state: Bool? = nil,
         enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let state { self.state = state ? .on : .off }
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// Menu bar item and menu (spec §2.1). The menu is rebuilt each time it opens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private lazy var settingsWindow = SettingsWindowController(backend: controller)
    private var statusItem: NSStatusItem?
    private var shownIcon: (state: AppController.IconState, tip: String)?
    /// How long the icon lingers after you leave AirFocus, in auto-hide mode.
    private static let autoHideDelay: TimeInterval = 5
    private var iconMode: MenuBarIconMode?
    private var menuOpen = false
    private var hideWork: DispatchWorkItem?
    private let menu = NSMenu()
    private var sigterm: DispatchSourceSignal?
    private static let hyper: NSEvent.ModifierFlags = [.control, .option, .command]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            // Two copies (e.g. build/ and ~/Applications) would fight over hotkeys and focus.
            Log.error(.app, "another AirFocus is already running; quitting this copy")
            NSApp.terminate(nil)
            return
        }
        // `pkill` (make run / make install) sends SIGTERM: quit cleanly so motion stops, any sleep
        // assertion is released and the log is flushed.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        term.resume()
        sigterm = term

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AirFocusStatusItem"   // keeps its spot when it reappears
        statusItem = item
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateIconVisibility() }
            }
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        controller.onChange = { [weak self] in self?.updateIcon() }
        controller.closeSettingsWindow = { [weak self] in self?.settingsWindow.closeIfOpen() ?? false }
        controller.launch()
        updateIcon()
    }

    /// Opening the app again while it runs (Finder, Spotlight, `open`, the Dock icon) means Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func openSettings() {
        // Calibration owns the screen and the Esc and Return keys until it finishes.
        guard !controller.isCalibrating else { return }
        settingsWindow.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: Icon

    private func updateIcon() {
        if controller.settings.menuBarIcon != iconMode {
            iconMode = controller.settings.menuBarIcon
            updateIconVisibility()
        }
        guard let button = statusItem?.button else { return }
        let state = controller.iconState
        let tip: String = {
            switch state {
            case .idle: return "AirFocus: idle"
            case .tracking: return "AirFocus: tracking"
            case .paused: return "AirFocus: switching paused until you recenter"
            case .calibrating: return "AirFocus: calibrating"
            case .away: return "AirFocus: away (screen saver)"
            case .problem: return "AirFocus: \(problemSummary())"
            }
        }()
        if let shownIcon, shownIcon.state == state, shownIcon.tip == tip { return }
        shownIcon = (state, tip)
        let image = MenuBarIcon.image(MenuBarIcon.Glyph(state), description: tip)
        button.image = image
        button.title = image == nil ? "AF" : ""
        // The art's off state is already dimmed; the SF Symbol fallback relies on the system's.
        button.appearsDisabled = state == .idle && !MenuBarIcon.hasArt
        button.toolTip = tip
    }

    /// In auto-hide mode the icon stays while AirFocus is in front (Settings is open) or its menu
    /// is, and goes a few seconds after you move on.
    private func updateIconVisibility() {
        hideWork?.cancel()
        hideWork = nil
        guard let item = statusItem else { return }
        switch iconMode ?? controller.settings.menuBarIcon {
        case .always:
            item.isVisible = true
        case .hidden:
            item.isVisible = false
        case .autoHide:
            if NSApp.isActive || menuOpen {
                item.isVisible = true
                return
            }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.iconMode == .autoHide, !NSApp.isActive, !self.menuOpen else { return }
                    self.statusItem?.isVisible = false
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideDelay, execute: work)
        }
    }

    private static func toggleAutoHide(_ c: AppController) {
        let turningOn = c.settings.menuBarIcon != .autoHide
        c.settings.menuBarIcon = turningOn ? .autoHide : .always
        c.settingsChanged()
        guard turningOn, !c.settings.autoHideExplained else { return }
        // Say once how to get the icon back, before it disappears.
        c.settings.autoHideExplained = true
        let alert = NSAlert()
        alert.messageText = "The menu bar icon will hide itself"
        alert.informativeText = "It disappears 5 seconds after you leave AirFocus. To bring it back, open AirFocus "
            + "again from Spotlight or the Applications folder. The ⌃⌥⌘ hotkeys keep working."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        c.settingsKeyChanged(true)          // the head mustn't pull focus away from the alert
        alert.runModal()
        c.settingsKeyChanged(false)
    }

    private func problemSummary() -> String {
        if !controller.axTrusted { return "Accessibility permission missing" }
        if controller.calibration == nil { return "not calibrated" }
        if !controller.isSimulating, [.denied, .restricted].contains(controller.motionAuthorization) {
            return "Motion & Fitness permission missing"
        }
        if controller.airpodsConnected == false { return "AirPods disconnected" }
        return "no head motion (AirPods connected and selected as the sound output?)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = controller

        // 1. Status lines
        for line in statusLines() { menu.addItem(line) }
        menu.addItem(.separator())

        // 2–5. Commands
        menu.addItem(ClosureMenuItem(c.trackingEnabled ? "Stop Tracking" : "Start Tracking", key: "t",
                                     modifiers: Self.hyper) { c.toggleTracking() })
        menu.addItem(ClosureMenuItem(c.calibration == nil ? "Calibrate…" : "Recalibrate…", key: "c",
                                     modifiers: Self.hyper, enabled: !c.isCalibrating) { c.calibrate() })
        menu.addItem(ClosureMenuItem("Recenter", key: "r", modifiers: Self.hyper,
                                     enabled: c.calibration != nil && c.trackingEnabled) { c.recenter() })
        menu.addItem(ClosureMenuItem("Reset & Recalibrate") { c.resetAndRecalibrate() })
        menu.addItem(ClosureMenuItem("Show Overlay", state: c.settings.overlayMode == .visible) { [weak self] in
            c.settings.overlayMode = c.settings.overlayMode == .visible ? .hidden : .visible
            c.settingsChanged()
            self?.settingsWindow.settingsChangedElsewhere()
        })
        menu.addItem(ClosureMenuItem("Auto-hide Menu Bar Icon", state: c.settings.menuBarIcon == .autoHide) { [weak self] in
            Self.toggleAutoHide(c)
            self?.settingsWindow.settingsChangedElsewhere()
        })
        menu.addItem(.separator())

        // 6. Settings
        menu.addItem(ClosureMenuItem("Settings…", key: ",", modifiers: .command, enabled: !c.isCalibrating) { [weak self] in
            self?.openSettings()
        })

        // 7. Developer
        let dev = NSMenu()
        dev.addItem(ClosureMenuItem("Simulate head with mouse", state: c.isSimulating) { c.setSimulation(!c.isSimulating) })
        dev.addItem(ClosureMenuItem("Open Log") {
            if !FileManager.default.fileExists(atPath: Log.fileURL.path) { Log.info(.app, "log opened") ; Log.flush() }
            NSWorkspace.shared.open(Log.fileURL)
        })
        dev.addItem(ClosureMenuItem("Copy Diagnostics") {
            let text = Diagnostics.report(runtime: c.runtimeDiagnostics)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Log.info(.app, "diagnostics copied to the clipboard")
        })
        dev.addItem(.separator())
        dev.addItem(ClosureMenuItem("Record Session Trace", state: c.settings.recordSessionTrace) {
            c.settings.recordSessionTrace.toggle()
            c.settingsChanged()
        })
        dev.addItem(ClosureMenuItem("Reveal Traces in Finder") { c.revealTraces() })
        dev.addItem(ClosureMenuItem("Delete Traces…") { Self.confirmDeleteTraces(c) })
        dev.addItem(.separator())
        dev.addItem(ClosureMenuItem("Relaunch AirFocus") { Self.relaunch() })
        menu.addItem(submenu("Developer", dev))
        menu.addItem(.separator())

        // 8. Quit
        menu.addItem(ClosureMenuItem("Quit AirFocus", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }

    private func statusLines() -> [NSMenuItem] {
        let c = controller
        var items: [NSMenuItem] = []

        // AirPods
        let airPods = c.airPodsStatus()
        items.append(info(airPods.text))
        if airPods.suggestSoundSettings {
            items.append(ClosureMenuItem("    Select AirPods as the sound output…") { AX.openSoundSettings() })
        }

        // Motion permission
        if !c.isSimulating {
            switch c.motionAuthorization {
            case .authorized: items.append(info("Motion & Fitness: allowed"))
            case .notDetermined: items.append(info("Motion & Fitness: asked when tracking starts"))
            case .denied, .restricted:
                items.append(ClosureMenuItem("Motion & Fitness: denied · Open Settings…") { AX.openMotionSettings() })
            @unknown default: items.append(info("Motion & Fitness: unknown"))
            }
        }

        // Accessibility
        if c.axTrusted {
            items.append(info("Accessibility: allowed"))
        } else {
            items.append(ClosureMenuItem("Accessibility: not allowed · Open Settings…") {
                AX.promptForTrust()
                AX.openAccessibilitySettings()
            })
        }

        // Calibration
        if let cal = c.calibration {
            let suffix = c.switchingPaused ? " · switching paused: ⌃⌥⌘R or type in the focused window" : ""
            items.append(info("Calibration: \(cal.summary)\(suffix)"))
        } else {
            items.append(info("Calibration: not calibrated"))
        }

        // Screen lock
        items.append(info("Screen lock: \(c.screenLock.menuText)"))

        if Screens.stageManagerEnabled {
            items.append(info("Stage Manager is on: keep your terminals in one stage"))
        }
        return items
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        updateIconVisibility()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        updateIconVisibility()
        controller.refreshScreenLock()
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        sub.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// Session traces are the intent engine's only record of real use: ask before deleting them.
    private static func confirmDeleteTraces(_ c: AppController) {
        let alert = NSAlert()
        alert.messageText = "Delete all session traces?"
        alert.informativeText = "They are local recordings of head motion, window frames, key-down times and clicks, kept to tune switching. A session being recorded starts a fresh file."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        c.settingsKeyChanged(true)          // the head mustn't pull focus away from the alert
        let delete = alert.runModal() == .alertFirstButtonReturn
        c.settingsKeyChanged(false)
        if delete { c.deleteTraces() }
    }

    /// For when the Accessibility grant seems cached (R§7.4): relaunch through LaunchServices.
    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
