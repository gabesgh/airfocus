import AppKit
import Carbon.HIToolbox
import CoreMotion
import AirFocusCore

/// The runtime pipeline (R§11.3): head pose → 1€ filter → affine map → look-away → target selector
/// → focuser + overlay. The decisions themselves are LiveSwitcher's (Core), so a trace replay runs
/// the same code; this class does the side effects. Everything here runs on the main thread; motion
/// arrives on its own serial queue and hops over, AX/focus work runs on the focuser's queue.
@MainActor
final class AppController {
    static let simulationKeyPrefix = "sim:"
    /// Head "still" for implicit recentring (stricter than the 25°/s switching gate).
    static let stillSpeed = 10.0
    /// Auto-anchor (see autoAnchor): typing burst into the focused window with a still head.
    static let anchorStillFor: TimeInterval = 1.5
    static let anchorBurstKeys = 3
    static let anchorBurstWindow: TimeInterval = 2.0

    /// Pause after a Recenter from the Settings window, whose button the user is looking at.
    static let settingsRecenterDelay: TimeInterval = 2
    /// Hidden mode's ⌃⌥⌘R: the focused window's dot shows this long, then the recenter happens.
    static let recenterCueDuration: TimeInterval = 1.0
    /// Lets the window server drop the Settings window and the previous app take focus first.
    static let settingsCloseSettle: TimeInterval = 0.2
    /// A pick ends Mission Control, so holding on a thumbnail takes twice as long as a switch.
    static let pickDwellFactor = 2.0
    /// How often the thumbnails are re-read while Mission Control is open.
    static let thumbnailRefresh: TimeInterval = 0.25
    /// Bursts this fast go in the log even when rejected, to tune the thresholds from real flicks.
    static let flickLogRate = 100.0

    /// What to aim at when switching is paused. Hidden mode has no highlighted window to point to.
    static func recenterHint(_ mode: OverlayMode) -> String {
        mode == .hidden
            ? "Switching paused: look at the middle of the focused window and press ⌃⌥⌘R, or just keep typing in it"
            : "Switching paused: look at the highlighted window and press ⌃⌥⌘R, or just keep typing in it"
    }

    enum IconState { case idle, tracking, paused, calibrating, away, problem }

    let settings = AppSettings()
    let store = CalibrationStore(defaults: .standard)
    let poller = WindowPoller()
    let focuser = WindowFocuser()
    let overlay = OverlayController()
    let keys = KeyActivity()
    let mouse = MouseActivity()
    let session = SessionStateObserver()
    let audio = AudioRouteMonitor()
    let lookAway: LookAwayController
    let trace = SessionTrace()

    /// One CMHeadphoneMotionManager for the app's lifetime (R§2), plus the mouse simulator.
    private let tracker = HeadTracker()
    private let simulator = MouseHeadSource()
    private(set) var source: HeadSource

    private(set) var calibration: HeadCalibration?
    private var calibrationController: CalibrationController?
    private(set) var trackingEnabled = false
    private(set) var airpodsConnected: Bool?
    private(set) var motionErrorText: String?
    private(set) var axTrusted = AX.isTrusted
    private(set) var screenLock: ScreenLockSetting = .unknown("not read yet")
    /// The stored map's yaw zero belongs to another stream, so the pointer can be anywhere:
    /// automatic and hotkey switching stay off until a recenter or auto-anchor.
    private(set) var yawNeedsRecenter = false {
        didSet { if oldValue != yawNeedsRecenter { applySelectorSettings() } }
    }
    private var recentKeyDowns: [TimeInterval] = []
    /// The Settings window or its colour panel is key, so automatic switching holds: the head would
    /// otherwise pull focus away while the user adjusts a slider. Deliberately not part of
    /// `switchingPaused`: the pointer, the highlight, ⌃⌥⌘F and the auto-anchor logic carry on.
    private var settingsHold = false {
        didSet {
            guard oldValue != settingsHold else { return }
            trace.emit(.mode(ProcessInfo.processInfo.systemUptime, .settings, settingsHold, ""))
            applySelectorSettings()
        }
    }
    private var calibrationStartPending = false
    private var settingsRecenterPending = false
    private var recenterCueGeneration = 0

    /// The live decision path: filter, map, selector, flick and Mission Control holds, focus adoption.
    private var live = LiveSwitcher()
    private var picker = ThumbnailPicker()
    private var thumbnails: [MissionControlThumbnail] = []
    private var thumbnailsReadAt: TimeInterval = 0
    private var implicit = ImplicitRecenterPolicy()
    private var envelope: AngleEnvelope?
    private var lastPose: (yaw: Double, pitch: Double, point: CGPoint, speed: Double, time: TimeInterval)?
    private var stillSince: TimeInterval?
    private var lastRequest: (time: TimeInterval, id: CGWindowID)?
    private var traceObscured = false
    private var trackingStartedAt: TimeInterval = 0
    private var streamEpoch = 0
    private var calibrationEpoch = -1
    private var activity: NSObjectProtocol?
    private var housekeeping: Timer?
    private var lastRateLog: TimeInterval = 0
    private var lastStatusSignature = ""
    private var tickCount = 0
    private var observers: [NSObjectProtocol] = []

    /// Status changed: refresh the menu bar icon (the menu itself refreshes when opened).
    var onChange: (() -> Void)?
    /// Closes the Settings window if it is open and says whether it was.
    var closeSettingsWindow: (() -> Bool)?

    init() {
        lookAway = LookAwayController(session: session, settings: settings)
        source = tracker
        if settings.simulateWithMouse { source = simulator }
    }

    // MARK: Lifecycle

    func launch() {
        Log.info(.app, "launch \(Diagnostics.version), pid \(ProcessInfo.processInfo.processIdentifier), \(Bundle.main.bundlePath)")
        settings.migrateLegacySettings()
        applySelectorSettings()
        overlay.apply(settings.overlayAppearance)
        overlay.setOverlayMode(settings.overlayMode)
        tracker.onEvent = { [weak self] in self?.handle($0, from: self?.tracker) }
        simulator.onEvent = { [weak self] in self?.handle($0, from: self?.simulator) }
        poller.onUpdate = { [weak self] in self?.windowsUpdated($0) }
        focuser.onResult = { [weak self] r in
            guard let self else { return }
            self.trace.emit(.focusResult(ProcessInfo.processInfo.systemUptime, r.windowID, verified: r.verified))
            guard !r.verified else { return }
            self.live.focusUnverified()     // let the next poll adopt what is really focused
        }
        keys.onKeyDown = { [weak self] in self?.keyDown(at: $0) }
        keys.start()
        mouse.onMouseDown = { [weak self] t, p, right in self?.mouseDown(at: t, point: p, right: right) }
        trace.makeHeader = { [weak self] session, part in
            self?.traceHeader(session: session, part: part) ?? (TraceHeader.placeholder, [])
        }
        trace.appName = { [weak self] id in self?.poller.windows.first { $0.id == id }?.appName }
        session.onChange = { [weak self] in self?.sessionChanged() }
        audio.onChange = { [weak self] in self?.audioRouteChanged() }
        lookAway.onEpisodeChange = { [weak self] away in self?.awayChanged(away) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Pick up click / ⌘-Tab focus changes right away instead of at the next poll.
            MainActor.assumeIsolated { if self?.poller.isRunning == true { self?.poller.refresh() } }
        })

        registerHotKeys()
        reloadCalibration()
        refreshScreenLock()
        trace.tidy()

        if !axTrusted {
            Log.info(.app, "Accessibility not granted: prompting")
            AX.promptForTrust()
        }
        Log.info(.app, "Accessibility \(axTrusted ? "granted" : "missing"); motion auth \(HeadTracker.authorization.label); "
                 + "Stage Manager \(Screens.stageManagerEnabled ? "on" : "off"); overlay \(settings.overlayMode.rawValue)")
        updateHousekeeping()
        if settings.trackingWasOn && calibration != nil {
            Log.info(.app, "resuming tracking from the last session")
            startTracking()
        }
        notifyIfChanged(force: true)
    }

    func shutdown() {
        Log.info(.app, "quit")
        if trackingEnabled { stopTracking(rememberIntent: false, quitting: true) }
        calibrationController?.cancel()
        lookAway.reset()
        source.stop()
        Log.flush()
    }

    private func registerHotKeys() {
        let hk = HotKeys.shared
        let mods = HotKeys.ctrlOptCmd
        let bindings: [(Int, String, () -> Void)] = [
            (kVK_ANSI_T, "⌃⌥⌘T", { [weak self] in self?.toggleTracking() }),
            (kVK_ANSI_C, "⌃⌥⌘C", { [weak self] in self?.calibrate() }),
            (kVK_ANSI_R, "⌃⌥⌘R", { [weak self] in self?.recenter() }),
            (kVK_ANSI_F, "⌃⌥⌘F", { [weak self] in self?.focusNow() }),
        ]
        for (code, label, action) in bindings where hk.register(keyCode: code, modifiers: mods, action) == nil {
            Log.error(.hotkeys, "could not register \(label)")
        }
    }

    // MARK: Derived state

    var isCalibrating: Bool { calibrationController != nil }
    var isSimulating: Bool { source.isSimulated }
    var switchingPaused: Bool { yawNeedsRecenter && !source.isSimulated }

    var displayKey: String { (source.isSimulated ? Self.simulationKeyPrefix : "") + Screens.configuration.key }

    /// Samples arrived within the last 1.5 s.
    var isStreaming: Bool {
        source.isRunning && ProcessInfo.processInfo.systemUptime - source.lastSampleUptime < 1.5
    }

    var motionAuthorization: CMAuthorizationStatus { HeadTracker.authorization }

    var lookAwayBlockReason: String? {
        if source.isSimulated { return "not available while simulating with the mouse" }
        if calibration == nil { return "needs a calibration" }
        if !trackingEnabled { return "needs tracking on" }
        if !axTrusted { return "needs Accessibility" }
        return nil
    }

    private var lookAwayActive: Bool { settings.lookAwayEnabled && lookAwayBlockReason == nil }

    var iconState: IconState {
        if isCalibrating { return .calibrating }
        if lookAway.episodeActive { return .away }
        if !axTrusted || calibration == nil { return .problem }
        if !source.isSimulated, motionAuthorization == .denied || motionAuthorization == .restricted { return .problem }
        if trackingEnabled {
            let grace = ProcessInfo.processInfo.systemUptime - trackingStartedAt < 3
            guard isStreaming || grace else { return .problem }
            return switchingPaused ? .paused : .tracking
        }
        return .idle
    }

    var currentTarget: TrackedWindow? {
        live.selector.current.flatMap { id in poller.windows.first { $0.id == id } }
    }

    // MARK: Commands

    func toggleTracking() {
        if trackingEnabled { stopTracking() } else { startTracking() }
    }

    func startTracking() {
        if isCalibrating { return }
        guard calibration != nil else {
            Log.info(.app, "start tracking requested without a calibration: calibrating first")
            startCalibration()
            return
        }
        guard !trackingEnabled else { return }
        trackingEnabled = true
        settings.trackingWasOn = true
        trackingStartedAt = ProcessInfo.processInfo.systemUptime
        live.startTracking()
        trace.begin(at: trackingStartedAt, record: settings.recordSessionTrace)
        traceObscured = session.isObscured
        applySelectorSettings()
        source.start()
        poller.start()
        mouse.start()
        beginActivity()
        Log.info(.app, "tracking started (\(source.isSimulated ? "mouse simulation" : "AirPods"))")
        if Screens.stageManagerEnabled && !settings.stageManagerNoticeShown && settings.showStatusBanners {
            settings.stageManagerNoticeShown = true
            overlay.showBanner("Stage Manager is on: it rearranges windows when focus changes.\nKeep your terminals in one stage, or turn Stage Manager off.",
                               style: .warning, duration: 8)
        }
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    func stopTracking(rememberIntent: Bool = true, quitting: Bool = false) {
        guard trackingEnabled else { return }
        trackingEnabled = false
        if rememberIntent { settings.trackingWasOn = false }
        lookAway.reset()
        cancelRecenterCue()
        if !isCalibrating {
            source.stop()
            poller.stop()
            endActivity()
        }
        mouse.stop()
        lastPose = nil
        trace.end(at: ProcessInfo.processInfo.systemUptime, quitting: quitting)
        Log.info(.app, "tracking stopped")
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    /// Calibrate… / Recalibrate… (⌃⌥⌘C).
    func calibrate() {
        if isCalibrating { return }
        startCalibration()
    }

    /// Reset & Recalibrate: clear the stored calibration, restart the motion stream, rescan, calibrate.
    func resetAndRecalibrate() {
        calibrationController?.cancel()
        Log.info(.calibration, "reset: clearing the stored calibration for \(displayKey)")
        store.clear(displayKey: displayKey)
        calibration = nil
        envelope = nil
        let now = ProcessInfo.processInfo.systemUptime
        trace.emit(.calibration(now, .cleared, nil, nil))
        if yawNeedsRecenter { trace.emit(.stream(now, .anchored, "reset")) }
        yawNeedsRecenter = false
        lookAway.reset()
        if source.isRunning { source.restart(reason: "reset & recalibrate") }
        startCalibration()
    }

    func startCalibration() {
        guard calibrationController == nil, !calibrationStartPending else { return }
        // From Settings (or a hotkey while it is open): behave exactly as from the menu, with the
        // window gone, the accessory policy back and the previous app frontmost.
        if closeSettingsWindow?() == true {
            calibrationStartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsCloseSettle) { [weak self] in
                MainActor.assumeIsolated {
                    self?.calibrationStartPending = false
                    self?.startCalibration()
                }
            }
            return
        }
        cancelRecenterCue()
        let windows = poller.refresh()
        let plan = CalibrationPlan.make(windows: windows.map { ($0.id, $0.targetPointCG) }, screensCG: Screens.framesCG)
        let cc = CalibrationController(plan: plan, windows: windows, displayKey: displayKey, overlay: overlay)
        cc.onFinish = { [weak self] outcome in self?.calibrationFinished(outcome) }
        calibrationController = cc
        live.resetFilter()
        trace.emit(.mode(ProcessInfo.processInfo.systemUptime, .calibrating, true, "\(plan.points.count) points"))
        source.start()
        poller.start()
        beginActivity()
        overlay.setSuspended(false)
        cc.begin()
        notifyIfChanged(force: true)
    }

    private func calibrationFinished(_ outcome: CalibrationController.Outcome) {
        calibrationController = nil
        overlay.setMode(.hidden)
        let now = ProcessInfo.processInfo.systemUptime
        switch outcome {
        case .success(let cal, let message, let warning):
            calibration = cal
            calibrationEpoch = streamEpoch
            store.save(cal)
            envelope = cal.envelope(screensCG: Screens.framesCG)
            trace.emit(.calibration(now, .calibrated, nil, cal))
            trace.emit(.mode(now, .calibrating, false, "calibrated"))
            if yawNeedsRecenter { trace.emit(.stream(now, .anchored, "calibration")) }
            yawNeedsRecenter = false
            implicit.resetBudget()
            lookAway.markYawAnchored()
            overlay.showBanner(message, style: warning ? .warning : .success, duration: warning ? 6 : 3)
            if !trackingEnabled { startTracking() } else { live.calibrated(); refreshOverlay() }
        case .cancelled:
            trace.emit(.mode(now, .calibrating, false, "cancelled"))
            overlay.hideBanner()
            resumeAfterCalibration()
        case .failed(let message):
            trace.emit(.mode(now, .calibrating, false, "failed"))
            overlay.showBanner(message, style: .warning, duration: 6)
            resumeAfterCalibration()
        }
        notifyIfChanged(force: true)
    }

    private func resumeAfterCalibration() {
        if trackingEnabled && calibration != nil {
            refreshOverlay()
        } else {
            trackingEnabled = false
            source.stop()
            poller.stop()
            endActivity()
            mouse.stop()
            trace.end(at: ProcessInfo.processInfo.systemUptime)
            refreshOverlay()
        }
    }

    /// Recenter (⌃⌥⌘R and the menu). Visible: at once, on the focused window's dot (R§8.6). Hidden:
    /// there's no dot to aim at, so the dot shows with a ring that fills for a second, and the
    /// recenter uses the pose at the end of it. Pressing again during that second starts it over.
    func recenter() {
        if isCalibrating { calibrationController?.captureNow(); return }
        guard settings.overlayMode == .hidden else { return recenterNow() }
        startRecenterCue(duration: Self.recenterCueDuration)
    }

    /// The one-point offset itself: the current pose maps onto the focused window's dot.
    private func recenterNow(preferring preferred: CGWindowID? = nil) {
        guard !isCalibrating else { return }
        guard var cal = calibration else {
            overlay.showBanner("Not calibrated yet: press ⌃⌥⌘C to calibrate", style: .warning, duration: 3)
            return
        }
        guard let pose = lastPose, ProcessInfo.processInfo.systemUptime - pose.time < 1.0 else {
            overlay.showBanner("No head motion right now: check that your AirPods are connected and selected as the sound output",
                               style: .warning, duration: 4)
            return
        }
        guard let target = preferred.flatMap({ id in poller.windows.first { $0.id == id } }) ?? recenterTarget() else {
            overlay.showBanner("No focused window to recenter on", style: .warning, duration: 3)
            return
        }
        cal.recenter(yaw: pose.yaw, pitch: pose.pitch, onto: target.targetPointCG)
        calibration = cal
        calibrationEpoch = streamEpoch
        store.save(cal)
        envelope = cal.envelope(screensCG: Screens.framesCG)
        let now = ProcessInfo.processInfo.systemUptime
        trace.emit(.calibration(now, .recenter, target.id, cal))
        if yawNeedsRecenter { trace.emit(.stream(now, .anchored, "recenter")) }
        yawNeedsRecenter = false
        lookAway.markYawAnchored()
        implicit.resetBudget()
        live.sync(target.id)
        Log.info(.calibration, "recentered on \(target.appName) wid \(target.id)")
        overlay.showBanner("Recentered on \(target.appName)", style: .success, duration: 1.5, near: target.targetPointCG, status: true)
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    /// The frontmost app's top window, or the selector's.
    private func recenterTarget() -> TrackedWindow? {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return poller.windows.first(where: { $0.pid == frontPID }) ?? currentTarget
    }

    /// Hidden mode: show the focused window's dot and a ring filling over `duration`, then recenter
    /// with the pose at that moment and fade the dot. One deferred step; nothing ticks meanwhile.
    private func startRecenterCue(duration: TimeInterval) {
        // The same checks as the recenter, up front, so a problem shows at once instead of after the second.
        guard calibration != nil else { return recenterNow() }
        guard let pose = lastPose, ProcessInfo.processInfo.systemUptime - pose.time < 1.0 else { return recenterNow() }
        guard let target = recenterTarget() else { return recenterNow() }
        recenterCueGeneration += 1
        let gen = recenterCueGeneration
        overlay.showRecenterCue(at: target.targetPointCG, duration: duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recenterCueGeneration == gen else { return }
                self.recenterNow(preferring: target.id)
                self.overlay.finishRecenterCue()
            }
        }
    }

    private func cancelRecenterCue() {
        recenterCueGeneration += 1
        overlay.cancelRecenterCue()
    }

    /// The Settings button. The user is looking at that button, not at the focused window, and a
    /// recenter trusts where the head points right now: give them a moment to turn first. In Hidden
    /// mode the wait shows the focused window's dot, so they know where to look.
    func recenterFromSettings() {
        guard calibration != nil, trackingEnabled else { return recenter() }
        guard !settingsRecenterPending else { return }
        settingsRecenterPending = true
        overlay.emphasizeCurrent()
        overlay.showBanner("Point your nose at the middle of the focused window: recentering in \(Int(Self.settingsRecenterDelay)) s",
                           near: currentTarget?.targetPointCG)
        if settings.overlayMode == .hidden {
            startRecenterCue(duration: Self.settingsRecenterDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsRecenterDelay) { [weak self] in
                MainActor.assumeIsolated { self?.settingsRecenterPending = false }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsRecenterDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.settingsRecenterPending = false
                self?.recenter()
            }
        }
    }

    /// The Settings window or its colour panel became or stopped being key.
    func settingsKeyChanged(_ key: Bool) { settingsHold = key }

    /// ⌃⌥⌘F: focus the window under the head pointer now (both focus modes).
    func focusNow() {
        guard trackingEnabled, calibration != nil, !session.isObscured, !lookAway.episodeActive else { return }
        if switchingPaused {
            overlay.showBanner(Self.recenterHint(settings.overlayMode), style: .info, duration: 3, near: currentTarget?.targetPointCG)
            return
        }
        guard let id = live.lastDecision.underPointer, let w = poller.windows.first(where: { $0.id == id }) else {
            overlay.showBanner("No window under the head pointer", style: .warning, duration: 1.5)
            return
        }
        live.manualFocus(id, now: ProcessInfo.processInfo.systemUptime)
        requestFocus(w, reason: .hotkey)
        overlay.update(current: id, pending: nil, progress: nil)
    }

    func setSimulation(_ on: Bool) {
        guard on != source.isSimulated else { return }
        calibrationController?.cancel()
        let wasTracking = trackingEnabled
        if wasTracking { stopTracking(rememberIntent: false) }
        source.stop()
        settings.simulateWithMouse = on
        source = on ? simulator : tracker
        Log.info(.app, "head source: \(on ? "mouse simulation" : "AirPods")")
        lookAway.reset()
        reloadCalibration()
        if wasTracking { startTracking() }
        notifyIfChanged(force: true)
    }

    func settingsChanged() {
        applySelectorSettings()
        overlay.apply(settings.overlayAppearance)
        if settings.overlayMode != overlay.overlayMode {
            Log.info(.app, "overlay \(settings.overlayMode.rawValue)")
            trace.emit(.mode(ProcessInfo.processInfo.systemUptime, .overlay, settings.overlayMode == .visible, ""))
            if settings.overlayMode == .visible { cancelRecenterCue() }
        }
        overlay.setOverlayMode(settings.overlayMode)
        overlay.update(windows: poller.windows)
        if !lookAwayActive { lookAway.reset() }
        trace.setRecording(settings.recordSessionTrace, at: ProcessInfo.processInfo.systemUptime)
        notifyIfChanged(force: true)
    }

    /// The AirPods status line, shared by the menu and the Settings status row.
    func airPodsStatus(includeRate: Bool = true) -> (text: String, suggestSoundSettings: Bool) {
        if isSimulating { return ("AirPods: simulated with the mouse (Developer menu)", false) }
        let output = AudioRoute.defaultOutput()
        if isStreaming {
            let rate = includeRate ? String(format: " · %.0f Hz", source.sampleRate) : ""
            return ("AirPods: connected\(rate) · output: \(output?.name ?? "unknown")", false)
        }
        if trackingEnabled && airpodsConnected == false { return ("AirPods: disconnected · tracking paused", false) }
        if !AudioRoute.headphoneCandidates().isEmpty || airpodsConnected == true {
            if let output, output.looksLikeHeadTrackingHeadphones {
                let waiting = source.isRunning ? " · waiting for motion" : ""
                return ("AirPods: connected\(waiting) · output: \(output.name)", false)
            }
            return ("AirPods: not the current audio output", true)
        }
        return (trackingEnabled ? "AirPods: disconnected · tracking paused" : "AirPods: not connected", false)
    }

    // MARK: Pipeline

    private func handle(_ event: HeadEvent, from origin: HeadSource?) {
        guard let origin, origin === source else { return }   // ignore the inactive source
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .sample(let s):
            handleSample(s)
        case .connected:
            airpodsConnected = true
            trace.emit(.stream(now, .connected, ""))
            if trackingEnabled { Log.info(.app, "AirPods connected: tracking resumes") }
            notifyIfChanged(force: true)
        case .disconnected:
            airpodsConnected = false
            trace.emit(.stream(now, .disconnected, ""))
            if trackingEnabled { Log.info(.app, "AirPods disconnected: tracking paused") }
            lastPose = nil
            refreshOverlay()
            notifyIfChanged(force: true)
        case .streamStarted(let isRestart):
            streamEpoch += 1
            airpodsConnected = true
            motionErrorText = nil
            trace.emit(.stream(now, isRestart ? .restarted : .started, ""))
            // A new stream has a new arbitrary yaw zero: a calibration from another stream needs a recentre.
            if calibration != nil && calibrationEpoch != streamEpoch && !isCalibrating {
                markYawUnanchored(reason: isRestart ? "motion stream restarted" : "motion stream started")
            }
            refreshOverlay()
            notifyIfChanged(force: true)
        case .referenceJump(let what):
            trace.emit(.stream(now, .jump, what))
            if calibration != nil && !isCalibrating { markYawUnanchored(reason: "reference jump (\(what))") }
        case .error(let error):
            let ns = error as NSError
            motionErrorText = ns.domain == CMErrorDomain && (ns.code == Int(CMErrorNotAuthorized.rawValue)
                                                             || ns.code == Int(CMErrorMotionActivityNotAuthorized.rawValue))
                ? "Motion & Fitness permission denied" : "motion error \(ns.domain) \(ns.code)"
            Log.error(.motion, "motion error: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            notifyIfChanged(force: true)
        }
    }

    private func markYawUnanchored(reason: String) {
        guard !source.isSimulated else { return }   // the mouse simulator's yaw is absolute
        Log.info(.motion, "yaw unanchored: \(reason)")
        trace.emit(.stream(ProcessInfo.processInfo.systemUptime, .unanchored, reason))
        yawNeedsRecenter = true
        lookAway.markYawUnanchored()
        if trackingEnabled {
            overlay.emphasizeCurrent()
            overlay.showBanner(Self.recenterHint(settings.overlayMode), style: .info, duration: 6,
                               near: currentTarget?.targetPointCG, status: true)
        }
        notifyIfChanged(force: true)
    }

    private func handleSample(_ s: HeadSample) {
        if let cc = calibrationController {
            cc.feed(s)
            trace.emit(.sample(TraceSample(s, flags: .calibrating)))
            return
        }
        guard trackingEnabled else { return }
        guard let cal = calibration else { return trace.emit(.sample(TraceSample(s, flags: .uncalibrated))) }
        if airpodsConnected != true { airpodsConnected = true; refreshOverlay(); notifyIfChanged(force: true) }

        let pose = live.track(s, map: cal.map)
        let point = pose.point
        let now = s.hostTime
        if s.speed < Self.stillSpeed { stillSince = stillSince ?? now } else { stillSince = nil }
        lastPose = (pose.yaw, pose.pitch, point, s.speed, now)

        if lookAwayActive, let env = envelope {
            lookAway.feed(yaw: pose.yaw, pitch: pose.pitch, speed: s.speed, now: now, envelope: env)
        }
        // The typing guard's input, once per sample; a key the monitor missed goes in the trace too.
        let lastKeyDown = keys.lastKeyDown
        trace.key(at: lastKeyDown)
        // Paused while away, while the screen saver runs or the session is locked.
        let gated = lookAway.episodeActive || session.isObscured
        defer { trace.emit(.sample(TraceSample(s, filtered: (pose.yaw, pose.pitch), point: point, flags: gated ? .gated : []))) }
        guard !gated else { return }
        if overlay.mode != .tracking { refreshOverlay() }

        let step = live.decide(s, pose: pose, calibration: cal, envelope: envelope, yawAnchored: !yawNeedsRecenter,
                               lastKeyDown: lastKeyDown, windows: poller.windows, screensCG: Screens.framesCG, gated: false)
        if let burst = step.burst { flickFinished(burst, now: now) }
        let paused = switchingPaused   // an unanchored pointer would only mislead
        switch step.stage {
        case .gated:
            return
        case .missionControl:
            overlay.update(pointer: paused ? nil : point)
            updateThumbnailPick(point: point, speed: s.speed, now: now)
        case .flickHold:
            overlay.update(current: live.selector.current, pending: nil, progress: nil)
            overlay.update(pointer: paused ? nil : point)
        case .selector:
            let d = step.decision
            trace.reject(d.reject, at: now)
            if let id = d.switchTo, let w = poller.windows.first(where: { $0.id == id }) {
                requestFocus(w, reason: .dwell)
            }
            // While Settings holds switching, show what's under the pointer as in hotkey-only mode.
            let automatic = settings.focusMode == .automatic && !settingsHold
            overlay.update(current: live.selector.current,
                           pending: paused ? nil : (automatic ? d.pending : d.underPointer),
                           progress: automatic && !paused ? d.pendingProgress : nil)
            overlay.update(pointer: paused ? nil : point)
        }
    }

    /// A finished flick burst: log it, and perform it if it fired. LiveSwitcher has already started
    /// the switching hold and dropped any half-finished dwell.
    private func flickFinished(_ burst: FlickDetector.Burst, now: TimeInterval) {
        if burst.rejection != .turnedOff, burst.fired || burst.peakRate >= Self.flickLogRate {
            Log.info(.gesture, burst.summary)
            trace.emit(.flick(now, burst))
        }
        guard burst.fired, let direction = burst.direction else { return }
        switch direction {
        case .up:
            HeadGestures.toggleMissionControl()
        case .left, .right:
            switch HeadGestures.moveDesktop(left: direction == .left) {
            case .moved, .unavailable:
                break
            case .shortcutOff:
                overlay.showBanner("Turn on “Move left/right a space” in System Settings › Keyboard › Keyboard Shortcuts › Mission Control",
                                   style: .warning, duration: 6)
            case .notTrusted:
                overlay.showBanner("Changing Desktop with a flick needs Accessibility permission", style: .warning, duration: 6)
            }
        }
        trace.emit(.mode(now, .flickHold, true, "\(LiveSwitcher.flickHold) s"))
    }

    /// Mission Control rearranges everything, however it was opened: only the pointer stays until it
    /// closes. LiveSwitcher has already dropped the selector's choice and started the hold on close.
    private func missionControlChanged(now: TimeInterval) {
        let open = live.missionControlOpen
        Log.info(.gesture, "Mission Control \(open ? "opened" : "closed")")
        trace.emit(.mode(now, .missionControl, open, ""))
        if !open { trace.emit(.mode(now, .missionControlHold, true, "\(LiveSwitcher.missionControlHold) s")) }
        thumbnails = []
        thumbnailsReadAt = 0
        overlay.update(pick: nil, progress: nil)
        if open { picker.begin(at: now) }
        refreshOverlay()
    }

    /// Holding the pointer on a thumbnail picks it. Keeps the overlay's highlight in step with the hold.
    private func updateThumbnailPick(point: CGPoint, speed: Double, now: TimeInterval) {
        guard settings.missionControlPick, !switchingPaused, !thumbnails.isEmpty else {
            overlay.update(pick: nil, progress: nil)
            return
        }
        let d = picker.update(point: point, frames: thumbnails.map(\.frame), speed: speed,
                              inputIdle: KeyActivity.secondsSinceUserInput, now: now)
        let candidate = d.candidate.map { thumbnails[$0] }
        overlay.update(pick: candidate?.frame, progress: d.progress)
        guard d.pick, let candidate else { return }
        if HeadGestures.press(candidate) {
            Log.info(.gesture, "Mission Control: picked a window by holding on it")
            trace.emit(.mode(now, .pick, true, ""))
        } else {
            Log.error(.gesture, "Mission Control: pressing the held window failed")
        }
    }

    private func requestFocus(_ w: TrackedWindow, reason: TraceEvent.FocusReason) {
        let now = ProcessInfo.processInfo.systemUptime
        live.focusRequested(w.id, at: now)
        lastRequest = (now, w.id)
        trace.emit(.focusRequest(now, w.id, reason))
        focuser.focus(w, reason: reason.rawValue)
    }

    private var liveConfig: LiveConfig {
        var c = LiveConfig()
        c.sensitivity = settings.sensitivity
        c.automatic = settings.focusMode == .automatic
        c.switchingPaused = switchingPaused
        c.settingsHold = settingsHold
        c.flickUp = settings.flickUpEnabled
        c.flickSideways = settings.flickSidewaysEnabled
        c.flickSensitivity = settings.flickSensitivity
        c.simulated = source.isSimulated
        return c
    }

    private func applySelectorSettings() {
        let c = liveConfig
        live.configure(c)
        picker.config.dwell = SensitivityTuning(sensitivity: c.sensitivity).dwell * Self.pickDwellFactor
        trace.config(c, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Window list refreshed (8 Hz while tracking or calibrating).
    private func windowsUpdated(_ windows: [TrackedWindow]) {
        let now = ProcessInfo.processInfo.systemUptime
        if live.updateMissionControl(poller.missionControlOpen, now: now) { missionControlChanged(now: now) }
        let front = frontWindow(in: windows)
        traceWindows(windows, front: front, now: now)
        if live.missionControlOpen {
            if settings.missionControlPick, now - thumbnailsReadAt >= Self.thumbnailRefresh {
                thumbnailsReadAt = now
                thumbnails = HeadGestures.thumbnails()
            }
            return
        }
        overlay.update(windows: windows)
        guard trackingEnabled, !isCalibrating else { return }
        let step = live.adoptFront(front, windows: windows, now: now)
        if let id = step.externalFocus, let w = windows.first(where: { $0.id == id }) {
            Log.info(.focus, "external focus change: \(w.appName) wid \(id)")
        }
        if step.showCurrent { overlay.update(current: live.selector.current) }
    }

    private func frontWindow(in windows: [TrackedWindow]) -> LiveSwitcher.Front {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID == ProcessInfo.processInfo.processIdentifier { return .own }
        return windows.first(where: { $0.pid == frontPID }).map { .window($0.id) } ?? .unknown
    }

    private func traceWindows(_ windows: [TrackedWindow], front: LiveSwitcher.Front, now: TimeInterval) {
        guard trace.active else { return }
        trace.windows(windows, at: now)
        trace.emit(.poll(now, front: front, missionControl: live.missionControlOpen))
        let id: CGWindowID? = { if case .window(let id) = front { return id }; return nil }()
        let ours = lastRequest.map { $0.id == id && now - $0.time < 2 } ?? false
        trace.front(id, at: now, ours: ours)
    }

    /// A mouse button went down somewhere else: where, and over which tracked window. Session
    /// traces and the intent engine's drift estimate use it; switching doesn't.
    private func mouseDown(at t: TimeInterval, point: CGPoint, right: Bool) {
        guard trackingEnabled else { return }
        let id = WindowFilter.window(at: point, in: poller.windows)?.id
        trace.emit(.click(t, right ? .right : .left, point, id))
    }

    /// Implicit recentring (R§8.6 item 2): typing into the focused window with a settled head.
    private func keyDown(at t: TimeInterval) {
        trace.key(at: t)
        recentKeyDowns.append(t)
        recentKeyDowns.removeAll { t - $0 > Self.anchorBurstWindow }
        if switchingPaused { return autoAnchor(at: t) }
        guard ImplicitRecenterPolicy.isEnabled, trackingEnabled, !isCalibrating, var cal = calibration,
              let pose = lastPose, let still = stillSince, t - pose.time < 0.5 else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = poller.windows
        guard let focused = windows.first(where: { $0.pid == frontPID }),
              implicit.shouldNudge(point: pose.point, focused: focused, windows: windows, settledFor: t - still, now: t)
        else { return }
        let applied = cal.nudge(yaw: pose.yaw, pitch: pose.pitch, towards: focused.targetPointCG,
                                fraction: implicit.fraction, maxDegrees: implicit.maxDegreesPerEvent)
        implicit.noteApplied(degrees: applied, now: t)
        calibration = cal
        store.save(cal)
        envelope = cal.envelope(screensCG: Screens.framesCG)
        trace.emit(.calibration(t, .nudge, nil, cal))
        Log.info(.calibration, String(format: "implicit recentre towards %@ wid %u: %.2f° (budget used %.1f°)",
                                      focused.appName, focused.id, applied, implicit.totalApplied))
    }

    /// While yaw is unanchored, a burst of typing into the focused window with a still head is taken
    /// as "I'm looking at this window": re-anchor yaw there, keeping the gravity-referenced pitch.
    /// Saves pressing ⌃⌥⌘R after every launch, reconnect or stream restart. UNVERIFIED heuristic.
    private func autoAnchor(at t: TimeInterval) {
        guard trackingEnabled, !isCalibrating, !lookAway.episodeActive, !session.isObscured,
              var cal = calibration, let pose = lastPose, t - pose.time < 0.5,
              let still = stillSince, t - still >= Self.anchorStillFor,
              recentKeyDowns.count >= Self.anchorBurstKeys else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let focused = poller.windows.first(where: { $0.pid == frontPID }) else { return }
        let shift = cal.reanchorYaw(yaw: pose.yaw, pitch: pose.pitch, onto: focused.targetPointCG)
        calibration = cal
        calibrationEpoch = streamEpoch
        store.save(cal)
        envelope = cal.envelope(screensCG: Screens.framesCG)
        trace.emit(.calibration(t, .anchor, focused.id, cal))
        trace.emit(.stream(t, .anchored, "typing"))
        yawNeedsRecenter = false
        lookAway.markYawAnchored()
        implicit.resetBudget()
        live.sync(focused.id)
        recentKeyDowns.removeAll()
        Log.info(.calibration, String(format: "auto-anchored yaw on %@ wid %u while typing (shift %.1f°)",
                                      focused.appName, focused.id, shift))
        overlay.showBanner("Anchored on \(focused.appName): switching is on", style: .success, duration: 1.5,
                           near: focused.targetPointCG, status: true)
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    // MARK: Session traces

    private func traceHeader(session id: String, part: Int) -> (TraceHeader, [TraceEvent]) {
        let now = ProcessInfo.processInfo.systemUptime
        var state = TraceState()
        state.current = live.selector.current
        state.yawAnchored = !yawNeedsRecenter
        state.missionControl = live.missionControlOpen
        state.settingsHold = settingsHold
        state.away = lookAway.episodeActive
        state.obscured = session.isObscured
        state.calibrating = isCalibrating
        let started = ISO8601DateFormatter().string(from: Date())
        let header = TraceHeader(app: Diagnostics.version, launch: trace.launch, session: id, part: part, started: started,
                                 uptime: now, displayKey: displayKey, screens: Screens.framesCG, calibration: calibration,
                                 settings: TraceSettings(settings, simulated: source.isSimulated), state: state)
        return (header, [.config(now, liveConfig), .windows(now, poller.windows.map(TraceWindow.init))])
    }

    func revealTraces() { SessionTrace.reveal() }

    func deleteTraces() { trace.deleteAll() }

    // MARK: Overlay, session, screens

    /// Decide what the overlay shows.
    private func refreshOverlay() {
        overlay.setSuspended(session.isObscured || lookAway.episodeActive)
        overlay.setPointerOnly(live.missionControlOpen)
        if isCalibrating { return }   // the calibration controller owns the overlay
        let show = trackingEnabled && calibration != nil && isStreaming && !lookAway.episodeActive
        overlay.setMode(show ? .tracking : .hidden)
        if show {
            overlay.update(windows: poller.windows)
            overlay.update(current: live.selector.current, pending: nil, progress: nil)
        }
    }

    private func sessionChanged() {
        lookAway.sessionChanged()
        if session.isObscured { Log.info(.session, "screen saver/lock active: overlay hidden, focusing paused") }
        if session.isObscured != traceObscured {
            traceObscured = session.isObscured
            trace.emit(.mode(ProcessInfo.processInfo.systemUptime, .obscured, traceObscured,
                             session.screenLocked ? "locked" : (session.screenSaverRunning ? "screen saver" : "")))
        }
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    private func awayChanged(_ away: Bool) {
        trace.emit(.mode(ProcessInfo.processInfo.systemUptime, .away, away, ""))
        if !away && trackingEnabled {
            // R§11.6 item 5: after unlock, restore and mark yaw for recentring.
            markYawUnanchored(reason: "returned from look-away")
        }
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    private func screensChanged() {
        Log.info(.app, "display configuration: \(Screens.configuration.key)")
        trace.emit(.display(ProcessInfo.processInfo.systemUptime, key: displayKey, screens: Screens.framesCG))
        reloadCalibration()
        if calibration == nil && trackingEnabled {
            overlay.showBanner("New display arrangement: calibrate with ⌃⌥⌘C", style: .warning, duration: 5)
        }
        refreshOverlay()
        notifyIfChanged(force: true)
    }

    private func reloadCalibration() {
        calibration = store.load(displayKey: displayKey)
        envelope = calibration?.envelope(screensCG: Screens.framesCG)
        calibrationEpoch = -1
        implicit.resetBudget()
        let now = ProcessInfo.processInfo.systemUptime
        trace.emit(.calibration(now, .reload, nil, calibration))
        if let c = calibration {
            Log.info(.calibration, "loaded calibration for this display configuration: \(c.summary)")
            // The stored yaw zero belongs to an earlier stream; the mouse simulator's is absolute.
            if !source.isSimulated { trace.emit(.stream(now, .unanchored, "calibration loaded")) }
            yawNeedsRecenter = !source.isSimulated
            if source.isSimulated { calibrationEpoch = streamEpoch }
        } else {
            Log.info(.calibration, "no calibration for this display configuration")
            if yawNeedsRecenter { trace.emit(.stream(now, .anchored, "no calibration")) }
            yawNeedsRecenter = false
        }
    }

    private func audioRouteChanged() {
        let out = AudioRoute.defaultOutput()
        Log.info(.motion, "audio output changed: \(out.map { "\($0.name) (\($0.transportName))" } ?? "none")")
        // UNVERIFIED whether a restart is required after a route change; it is cheap and the
        // watchdog would do it anyway.
        if source.isRunning && !source.isSimulated { source.restart(reason: "audio route changed") }
        notifyIfChanged(force: true)
    }

    // MARK: Housekeeping (1 Hz)

    /// Runs while tracking, calibrating, or waiting for the Accessibility grant; idle otherwise.
    private func updateHousekeeping() {
        let needed = trackingEnabled || isCalibrating || !axTrusted
        if needed && housekeeping == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.housekeep() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            housekeeping = t
        } else if !needed, let t = housekeeping {
            t.invalidate()
            housekeeping = nil
        }
    }

    private func housekeep() {
        tickCount += 1
        let active = trackingEnabled || isCalibrating
        // Accessibility has no change callback: poll every second while missing, every 5 s otherwise.
        if !axTrusted || tickCount % 5 == 0 {
            let trusted = AX.isTrusted
            if trusted != axTrusted {
                axTrusted = trusted
                Log.info(.app, "Accessibility \(trusted ? "granted" : "revoked")")
                keys.start()
                if !lookAwayActive { lookAway.reset() }
            }
        }
        guard active else { return notifyIfChanged() }

        let now = ProcessInfo.processInfo.systemUptime
        trace.tick()
        if trackingEnabled && !isCalibrating {
            let streaming = isStreaming
            if (overlay.mode == .tracking) != (streaming && calibration != nil && !lookAway.episodeActive) { refreshOverlay() }
            if !streaming {
                lastPose = nil
                if lookAwayActive { lookAway.feedNoMotion(now: now) }
            }
            if streaming && now - lastRateLog >= 60 {
                lastRateLog = now
                Log.info(.motion, String(format: "sample rate %.0f Hz", source.sampleRate))
            }
            if lookAway.episodeActive {
                if tickCount % 5 == 0 { session.poll() }
                // The unlock notification can beat CGSession's locked flag, and nothing else re-checks.
                lookAway.sessionChanged()
            }
        }
        notifyIfChanged()
    }

    private func notifyIfChanged(force: Bool = false) {
        updateHousekeeping()
        let sig = "\(iconState)|\(trackingEnabled)|\(isCalibrating)|\(axTrusted)|\(isStreaming)|\(airpodsConnected.map { "\($0)" } ?? "-")|\(calibration != nil)|\(yawNeedsRecenter)|\(motionAuthorization.rawValue)"
        guard force || sig != lastStatusSignature else { return }
        lastStatusSignature = sig
        onChange?()
    }

    private func beginActivity() {
        // An agent with only a status item and a transparent overlay is a candidate for App Nap
        // timer throttling; cheap insurance (R§1.7, UNVERIFIED whether needed).
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "AirFocus head tracking")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func refreshScreenLock() {
        DispatchQueue.global(qos: .utility).async {
            let value = ScreenLockSetting.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.screenLock = value
                    Log.info(.lookAway, "screen lock setting: \(value.menuText)")
                }
            }
        }
    }

    // MARK: Diagnostics

    var runtimeDiagnostics: [String] {
        let now = ProcessInfo.processInfo.systemUptime
        var lines = [
            "tracking: \(trackingEnabled ? "on" : "off"); calibrating: \(isCalibrating); source: \(source.isSimulated ? "mouse simulation" : "AirPods")",
            String(format: "sample rate: %.0f Hz; last sample %@", source.sampleRate,
                   source.lastSampleUptime > 0 ? String(format: "%.1f s ago", now - source.lastSampleUptime) : "never"),
            "AirPods connected (motion delegate): \(airpodsConnected.map { "\($0)" } ?? "unknown")",
            "yaw needs recenter: \(yawNeedsRecenter)",
            String(format: "focus mode: %@; sensitivity %.2f (dwell %.0f ms); settings hold: %@; overlay: %@", settings.focusMode.rawValue,
                   settings.sensitivity, settings.tuning.dwell * 1000, settingsHold ? "yes" : "no", settings.overlayMode.rawValue),
            "tracked windows: \(poller.windows.count); current target: \(currentTarget.map { "\($0.appName) \($0.id)" } ?? "none")",
            "look-away: \(settings.lookAwayEnabled ? "on" : "off")\(lookAwayBlockReason.map { " (\($0))" } ?? ""); delay \(Int(settings.lookAwayDelay)) s; episode active: \(lookAway.episodeActive); lock immediately: \(settings.lockImmediately)",
            "session: locked \(session.screenLocked), screen saver \(session.screenSaverRunning), display asleep \(session.displayAsleep)",
            "session trace: \(settings.recordSessionTrace ? (trace.recording ? "recording" : "on, not tracking") : "off"); intent engine: shadow mode",
        ]
        if let e = envelope {
            lines.append(String(format: "envelope: yaw %.1f…%.1f°, pitch %.1f…%.1f°", e.yawMin, e.yawMax, e.pitchMin, e.pitchMax))
        }
        if let p = lastPose {
            lines.append(String(format: "last pose: yaw %.1f°, pitch %.1f°, speed %.0f°/s → (%.0f, %.0f)", p.yaw, p.pitch, p.speed, p.point.x, p.point.y))
        }
        if let m = motionErrorText { lines.append("motion error: \(m)") }
        return lines
    }
}

extension TraceHeader {
    /// Only if the controller is gone while a trace part starts; never written in practice.
    static var placeholder: TraceHeader {
        TraceHeader(app: "", launch: "", session: "", part: 0, started: "", uptime: 0, displayKey: "", screens: [],
                    calibration: nil, settings: TraceSettings(), state: TraceState())
    }
}
