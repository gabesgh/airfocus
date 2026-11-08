import AppKit
import Carbon.HIToolbox
import AirFocusCore

/// Runs one calibration (R§8.3, spec §2.3): the layout is frozen at the start, every point is
/// captured automatically (settle → average → validate), Return captures now and Esc cancels.
/// Return/Esc are global Carbon hotkeys only while this runs.
@MainActor
final class CalibrationController {
    enum Outcome {
        case success(HeadCalibration, message: String, warning: Bool)
        case cancelled
        case failed(String)
    }

    /// The banner names the dot's colour only when it is the default white one.
    static func instruction(dotColor: StyleColor) -> String {
        "Point your nose at the \(dotColor == .white ? "white" : "pulsing") dot and hold still"
    }
    /// Banner warning thresholds (R§8.3): mean angular error, or RMS beyond 30% of a typical window.
    static let warnDegrees = 3.0
    static let warnWindowFraction = 0.3

    var onFinish: ((Outcome) -> Void)?

    private let overlay: OverlayController
    private let points: [CalibrationPoint]
    private let windows: [TrackedWindow]
    private let displayKey: String
    private var states: [CalibrationDotState]
    private var index = 0
    private var capture = CalibrationCapture()
    private var samples: [CalibrationSample] = []
    private var anchors: [WindowAnchor] = []
    private var keyTokens: [HotKeys.Token] = []
    private var chordKeys = false
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var lastSampleAt: TimeInterval = 0
    private var waitingBannerShown = false
    private var finished = false

    init(plan: CalibrationPlan.Result, windows: [TrackedWindow], displayKey: String, overlay: OverlayController) {
        self.points = plan.points
        self.windows = windows
        self.displayKey = displayKey
        self.overlay = overlay
        self.states = Array(repeating: .pending, count: plan.points.count)
        var reasons: [String] = []
        if plan.reasons.fewWindows { reasons.append("fewer than 3 windows") }
        if plan.reasons.collinearX || plan.reasons.collinearY { reasons.append("windows nearly in a line") }
        if !plan.reasons.emptyScreens.isEmpty { reasons.append("screen(s) \(plan.reasons.emptyScreens) without windows") }
        let windowCount = plan.points.filter { $0.windowID != nil }.count
        Log.info(.calibration, "calibration start: \(plan.points.count) points (\(windowCount) windows)"
                 + (reasons.isEmpty ? "" : "; screen points added: " + reasons.joined(separator: ", ")))
    }

    var pointCount: Int { points.count }
    private var instruction: String { Self.instruction(dotColor: overlay.appearance.dotColor) }

    func begin() {
        registerKeys()
        startedAt = ProcessInfo.processInfo.systemUptime
        lastSampleAt = startedAt
        guard !points.isEmpty else { return finish() }
        states[0] = .active
        capture.begin(at: startedAt, expectTravel: false)
        overlay.setMode(.calibrating)
        render()
        showInstruction()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func feed(_ s: HeadSample) {
        guard !finished, index < points.count else { return }
        lastSampleAt = s.hostTime
        if waitingBannerShown { waitingBannerShown = false; showInstruction() }
        switch capture.feed(yaw: s.yaw, pitch: s.pitch, speed: s.speed, now: s.hostTime) {
        case .captured(let m): record(m)
        case .rejected(let sd):
            Log.info(.calibration, String(format: "point %d rejected (std dev %.2f°), retrying", index + 1, sd))
        case .timedOut: skip()
        case .none: break
        }
    }

    /// Return: capture the current point immediately.
    func captureNow() {
        guard !finished else { return }
        if let m = capture.captureNow() {
            Log.info(.calibration, "point \(index + 1) captured manually")
            record(m)
        } else {
            NSSound.beep()
        }
    }

    /// Esc.
    func cancel() {
        guard !finished else { return }
        Log.info(.calibration, "calibration cancelled at point \(index + 1) of \(points.count)")
        teardown()
        onFinish?(.cancelled)
    }

    // MARK: -

    private func registerKeys() {
        let hk = HotKeys.shared
        let esc = hk.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.cancel() }
        let ret = hk.register(keyCode: kVK_Return, modifiers: 0) { [weak self] in self?.captureNow() }
        if let esc, let ret {
            keyTokens = [esc, ret]
            return
        }
        hk.unregister(esc)
        hk.unregister(ret)
        chordKeys = true
        Log.error(.hotkeys, "plain Esc/Return unavailable; using ⌃⌥⌘Esc / ⌃⌥⌘Return for calibration")
        keyTokens = [
            hk.register(keyCode: kVK_Escape, modifiers: HotKeys.ctrlOptCmd) { [weak self] in self?.cancel() },
            hk.register(keyCode: kVK_Return, modifiers: HotKeys.ctrlOptCmd) { [weak self] in self?.captureNow() },
        ].compactMap { $0 }
    }

    private func showInstruction() {
        let cancelKey = chordKeys ? "⌃⌥⌘Esc" : "Esc"
        let captureKey = chordKeys ? "⌃⌥⌘Return" : "Return"
        var text = "\(instruction) · \(cancelKey) to cancel\nPoint \(min(index + 1, points.count)) of \(points.count) · \(captureKey) captures now"
        if chordKeys { text += " (plain Esc/Return unavailable)" }
        overlay.showBanner(text, style: .info, near: index < points.count ? points[index].pointCG : nil)
    }

    private func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if case .timedOut = capture.checkTimeout(now: now) { return skip() }
        if now - lastSampleAt > 2.5, !waitingBannerShown {
            waitingBannerShown = true
            overlay.showBanner("Waiting for head motion: are your AirPods in your ears and selected as the sound output?\n\(instruction) · Esc to cancel",
                               style: .warning, near: points[index].pointCG)
        }
        render(now: now)
    }

    private func record(_ m: CalibrationCapture.Measurement) {
        let p = points[index]
        samples.append(CalibrationSample(yaw: m.yaw, pitch: m.pitch, screen: p.pointCG))
        if let wid = p.windowID {
            anchors.append(WindowAnchor(windowID: wid, dotCG: p.pointCG, yaw: m.yaw, pitch: m.pitch))
        }
        states[index] = .done
        Log.info(.calibration, String(format: "point %d/%d captured: yaw %.1f°, pitch %.1f°, std dev %.2f° over %d samples",
                                      index + 1, points.count, m.yaw, m.pitch, m.stdDev, m.count))
        advance()
    }

    private func skip() {
        states[index] = .skipped
        Log.info(.calibration, "point \(index + 1)/\(points.count) skipped after \(Int(capture.config.timeout)) s")
        advance()
    }

    private func advance() {
        index += 1
        guard index < points.count else { return finish() }
        states[index] = .active
        capture.begin(at: ProcessInfo.processInfo.systemUptime)
        render()
        if !waitingBannerShown { showInstruction() }
    }

    private func render(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        overlay.update(calibration: Array(zip(points.map(\.pointCG), states)), progress: capture.progress(now: now))
    }

    private func teardown() {
        finished = true
        timer?.invalidate()
        timer = nil
        keyTokens.forEach { HotKeys.shared.unregister($0) }
        keyTokens.removeAll()
    }

    private func finish() {
        teardown()
        render()
        guard samples.count >= 3 else {
            Log.error(.calibration, "calibration failed: only \(samples.count) point(s) captured")
            onFinish?(.failed("Calibration failed: only \(samples.count) point(s) captured. Check that head motion is arriving and try again."))
            return
        }
        guard let cal = HeadCalibration.fit(samples: samples, anchors: anchors, displayKey: displayKey) else {
            Log.error(.calibration, "calibration failed: degenerate fit from \(samples.count) points")
            onFinish?(.failed("Calibration failed: the captured poses were too close together. Point with your nose and try again."))
            return
        }
        let widths = windows.map { Double($0.frameCG.width) }.sorted()
        let medianWidth = widths.isEmpty ? 800 : widths[widths.count / 2]
        let warn = cal.meanErrorDegrees > Self.warnDegrees || cal.rmsErrorPoints > Self.warnWindowFraction * medianWidth
        var message = String(format: "Calibrated · %d points · average error %.1f°", samples.count, cal.meanErrorDegrees)
        if warn { message += "\nThat's high: recalibrate (⌃⌥⌘C) and point with your nose, not just your eyes" }
        let skipped = states.filter { $0 == .skipped }.count
        if skipped > 0 { message += "\n\(skipped) point(s) skipped" }
        Log.info(.calibration, String(format: "calibration done: %d points, mean error %.2f°, rms %.0f pt, %d anchors, %d skipped%@",
                                      samples.count, cal.meanErrorDegrees, cal.rmsErrorPoints, anchors.count, skipped,
                                      warn ? " (warning: high error)" : ""))
        onFinish?(.success(cal, message: message, warning: warn))
    }
}
