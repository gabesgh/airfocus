import CoreGraphics
import XCTest
@testable import AirFocusCore

/// AppController's decision path as it was before LiveSwitcher existed, transcribed line for line
/// from that version (handleSample, flickFinished, missionControlChanged, windowsUpdated,
/// requestFocus, applySelectorSettings, focusNow, recenter, the focuser's result), minus the overlay,
/// gestures and log. The equivalence test drives it and LiveSwitcher side by side.
private struct BaselineLivePath {
    var filter = HeadPoseFilter()
    var selector = TargetSelector()
    var flicks = FlickDetector()
    var flickHoldUntil: TimeInterval = 0
    var missionControlOpen = false
    var adoptWithHold = false
    var lastFrontWindow: CGWindowID?
    var lastFocusRequestAt: TimeInterval = -.infinity
    var lastDecision = TargetSelector.Decision()
    var config = LiveConfig()

    enum Outcome: Equatable { case gated, missionControl, flickHold, selector(TargetSelector.Decision) }

    mutating func applySelectorSettings() {
        let tuning = SensitivityTuning(sensitivity: config.sensitivity)
        tuning.apply(to: &selector.config)
        filter.setTuning(minCutoff: tuning.filterMinCutoff, beta: tuning.filterBeta, dCutoff: tuning.filterDCutoff)
        selector.config.autoSwitch = config.automatic && !config.switchingPaused && !config.settingsHold
        var flickConfig = FlickDetector.Config(sensitivity: config.flickSensitivity)
        flickConfig.upEnabled = config.flickUp
        flickConfig.sidewaysEnabled = config.flickSideways
        flicks.config = flickConfig
    }

    mutating func handleSample(_ s: HeadSample, cal: HeadCalibration, envelope: AngleEnvelope?, yawAnchored: Bool,
                               lastKeyDown: TimeInterval, windows: [TrackedWindow], screens: [CGRect], gated: Bool)
        -> (outcome: Outcome, burst: FlickDetector.Burst?, point: CGPoint, switched: CGWindowID?) {
        let f = filter.filter(yaw: s.yaw, pitch: s.pitch, at: s.deviceTime)
        let point = cal.map.point(yaw: f.yaw, pitch: f.pitch)
        let now = s.hostTime
        guard !gated else { return (.gated, nil, point, nil) }
        var burst: FlickDetector.Burst?
        if !config.simulated, config.flickUp || config.flickSideways,
           let b = flicks.update(yaw: s.yaw, pitch: s.pitch, speed: s.speed, time: s.deviceTime, envelope: envelope,
                                 yawAnchored: yawAnchored, secondsSinceKey: now - lastKeyDown) {
            burst = b
            flickFinished(b, now: now)
        }
        if missionControlOpen { return (.missionControl, burst, point, nil) }
        if now < flickHoldUntil { return (.flickHold, burst, point, nil) }
        let input = TargetSelector.Input(
            point: point, yaw: f.yaw, pitch: f.pitch, speed: s.speed, now: now, lastKeyDown: lastKeyDown,
            windows: windows, screensCG: screens, lowestCalibratedPitch: cal.lowestCalibratedPitch,
            gapResolver: { yaw, pitch, ws in cal.nearestWindowByAngle(yaw: yaw, pitch: pitch, windows: ws) })
        let d = selector.update(input)
        lastDecision = d
        var switched: CGWindowID?
        if let id = d.switchTo, windows.contains(where: { $0.id == id }) {
            requestFocus(id, now: now)
            switched = id
        }
        return (.selector(d), burst, point, switched)
    }

    mutating func flickFinished(_ burst: FlickDetector.Burst, now: TimeInterval) {
        guard burst.fired, burst.direction != nil else { return }
        flickHoldUntil = now + 1.6
        selector.syncCurrent(selector.current)
    }

    mutating func requestFocus(_ id: CGWindowID, now: TimeInterval) {
        lastFocusRequestAt = now
        lastFrontWindow = id
    }

    /// Returns (overlay current updated, external focus logged).
    mutating func windowsUpdated(_ windows: [TrackedWindow], missionControl: Bool, frontPID: pid_t?, ownPID: pid_t,
                                 active: Bool, now: TimeInterval) -> (Bool, CGWindowID?) {
        if missionControl != missionControlOpen {
            missionControlOpen = missionControl
            if !missionControlOpen {
                selector.syncCurrent(nil)
                adoptWithHold = true
                lastFrontWindow = nil
                flickHoldUntil = now + 0.6
            }
        }
        if missionControlOpen { return (false, nil) }
        guard active else { return (false, nil) }
        if frontPID == ownPID {
            if selector.current == nil, let top = windows.first?.id {
                selector.syncCurrent(top)
                return (true, nil)
            }
            return (false, nil)
        }
        guard let front = windows.first(where: { $0.pid == frontPID })?.id else { return (false, nil) }
        var logged: CGWindowID?
        if selector.current == nil {
            if adoptWithHold {
                adoptWithHold = false
                selector.adoptWithHold(front, now: now)
            } else {
                selector.syncCurrent(front)
            }
        } else if front != selector.current && now - lastFocusRequestAt > 1.0 {
            if front != lastFrontWindow { logged = front }
            selector.noteExternalFocus(front, now: now)
        }
        lastFrontWindow = front
        return (true, logged)
    }
}

final class LiveSwitcherTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let ownPID: pid_t = 999
    private lazy var windows: [TrackedWindow] = [
        TrackedWindow(id: 1, pid: 10, appName: "A", frameCG: CGRect(x: 0, y: 25, width: 1280, height: 1415)),
        TrackedWindow(id: 2, pid: 20, appName: "B", frameCG: CGRect(x: 1280, y: 25, width: 1280, height: 707)),
        TrackedWindow(id: 3, pid: 30, appName: "C", frameCG: CGRect(x: 1280, y: 732, width: 1280, height: 708)),
    ]
    private let calibration: HeadCalibration = {
        let map = AffineHeadMap(a: [1244, -64, 3], b: [0, -2, -60])
        let points = [CGPoint(x: 1280, y: 720), CGPoint(x: 384, y: 216), CGPoint(x: 2176, y: 216), CGPoint(x: 384, y: 1224),
                      CGPoint(x: 2176, y: 1224)]
        let samples = points.map { p -> CalibrationSample in
            let a = map.angles(for: p)!
            return CalibrationSample(yaw: a.yaw, pitch: a.pitch, screen: p)
        }
        return HeadCalibration(map: map, samples: samples, anchors: [WindowAnchor(windowID: 2, dotCG: CGPoint(x: 1920, y: 378), yaw: -10, pitch: -6)],
                               displayKey: "test")
    }()

    private func front(_ pid: pid_t?, _ windows: [TrackedWindow]) -> LiveSwitcher.Front {
        if pid == ownPID { return .own }
        return windows.first(where: { $0.pid == pid }).map { .window($0.id) } ?? .unknown
    }

    /// The extraction changed nothing: thousands of random samples, polls, flicks, Mission Control
    /// openings, focus failures, hotkeys, recenters, setting changes and keys, decided the old way
    /// and the new way, compared at every step.
    func testLiveSwitcherDecidesExactlyAsTheAppDidBeforeTheExtraction() {
        for seed: UInt64 in [1, 2, 3, 4, 5, 6] {
            var rng = SplitMix64(seed: seed)
            var old = BaselineLivePath()
            var new = LiveSwitcher()
            var config = LiveConfig()
            old.config = config
            old.applySelectorSettings()
            new.configure(config)
            var t = 500.0, yaw = 0.0, pitch = -12.0
            var lastKey = -100.0
            var frontPID: pid_t? = 10
            var mc = false
            var yawAnchored = true
            var flick: (dyaw: Double, dpitch: Double, left: Int, total: Int)?
            var switches = 0, flicksFired = 0, mcCycles = 0, adopted = 0
            let envelope = calibration.envelope(screensCG: [screen])
            var target = (yaw: 0.0, pitch: -12.0)
            for step in 0..<20000 {
                t += 0.02 + rng.uniform(-0.002, 0.002)
                // Head: wander towards a target that jumps now and then, with the odd sharp flick.
                if rng.uniform(0, 1) < 0.01 { target = (rng.uniform(-18, 18), rng.uniform(-22, -2)) }
                if flick == nil, rng.uniform(0, 1) < 0.002 {
                    let up = rng.uniform(0, 1) < 0.4
                    flick = (up ? 0 : (rng.uniform(0, 1) < 0.5 ? 20 : -20), up ? 14 : 0, 7, 7)
                }
                let lastYaw = yaw, lastPitch = pitch
                if let f = flick {
                    let i = Double(f.total - f.left + 1) / Double(f.total), j = Double(f.total - f.left) / Double(f.total)
                    func mj(_ x: Double) -> Double { x * x * x * (10 - 15 * x + 6 * x * x) }
                    yaw += f.dyaw * (mj(i) - mj(j))
                    pitch += f.dpitch * (mj(i) - mj(j))
                    flick = f.left > 1 ? (f.dyaw, f.dpitch, f.left - 1, f.total) : nil
                } else {
                    yaw += (target.yaw - yaw) * 0.08 + rng.normal() * 0.05
                    pitch += (target.pitch - pitch) * 0.08 + rng.normal() * 0.05
                }
                let speed = hypot(yaw - lastYaw, pitch - lastPitch) / 0.02 + abs(rng.normal())
                let s = HeadSample(yaw: yaw, pitch: pitch, speed: speed, deviceTime: t - 0.003, hostTime: t)

                // Everything else that can happen between samples.
                let r = rng.uniform(0, 1)
                if r < 0.006 { lastKey = t - rng.uniform(0, 0.01) }
                if step % 6 == 0 {
                    if rng.uniform(0, 1) < 0.05 { frontPID = [10, 20, 30, ownPID, 77, nil][Int(rng.uniform(0, 5.999))] }
                    if rng.uniform(0, 1) < (mc ? 0.06 : 0.002) { mc.toggle(); if !mc { mcCycles += 1 } }
                    let o = old.windowsUpdated(windows, missionControl: mc, frontPID: frontPID, ownPID: ownPID, active: true, now: t)
                    let n = new.windowsUpdated(windows, missionControlOpen: mc, front: front(frontPID, windows), active: true, now: t)
                    XCTAssertEqual(o.0, n.showCurrent, "seed \(seed) step \(step)")
                    XCTAssertEqual(o.1, n.externalFocus, "seed \(seed) step \(step)")
                    if n.externalFocus != nil { adopted += 1 }
                }
                if r > 0.997 {
                    old.lastFocusRequestAt = -.infinity
                    new.focusUnverified()
                } else if r > 0.995, let id = old.lastDecision.underPointer {
                    old.selector.noteManualFocus(id, now: t)
                    old.requestFocus(id, now: t)
                    new.manualFocus(id, now: t)
                    new.focusRequested(id, at: t)
                } else if r > 0.993 {
                    let id = windows[Int(rng.uniform(0, 2.999))].id
                    old.selector.syncCurrent(id); old.lastFrontWindow = id
                    new.sync(id)
                } else if r > 0.992 {
                    config.sensitivity = SensitivityTuning.snapped(rng.uniform(0, 1))
                    config.automatic = rng.uniform(0, 1) < 0.8
                    config.switchingPaused = rng.uniform(0, 1) < 0.15
                    config.settingsHold = rng.uniform(0, 1) < 0.15
                    config.flickUp = rng.uniform(0, 1) < 0.8
                    config.flickSideways = rng.uniform(0, 1) < 0.8
                    config.flickSensitivity = rng.uniform(0, 1)
                    yawAnchored = !config.switchingPaused
                    old.config = config
                    old.applySelectorSettings()
                    new.configure(config)
                } else if r > 0.9915 {
                    old.selector.reset(); old.lastFrontWindow = nil
                    new.calibrated()
                } else if r > 0.9912 {
                    old.filter.reset(); old.selector.reset(); old.lastFrontWindow = nil
                    old.applySelectorSettings()
                    new.startTracking()
                    new.configure(config)
                } else if r > 0.9910 {
                    old.filter.reset()
                    new.resetFilter()
                }

                let gated = rng.uniform(0, 1) < 0.01
                let o = old.handleSample(s, cal: calibration, envelope: envelope, yawAnchored: yawAnchored, lastKeyDown: lastKey,
                                         windows: windows, screens: [screen], gated: gated)
                let pose = new.track(s, map: calibration.map)
                let n = new.decide(s, pose: pose, calibration: calibration, envelope: envelope, yawAnchored: yawAnchored,
                                   lastKeyDown: lastKey, windows: windows, screensCG: [screen], gated: gated)
                XCTAssertEqual(o.point, pose.point, "seed \(seed) step \(step)")
                XCTAssertEqual(o.burst, n.burst, "seed \(seed) step \(step)")
                switch o.outcome {
                case .gated: XCTAssertEqual(n.stage, .gated, "seed \(seed) step \(step)")
                case .missionControl: XCTAssertEqual(n.stage, .missionControl, "seed \(seed) step \(step)")
                case .flickHold: XCTAssertEqual(n.stage, .flickHold, "seed \(seed) step \(step)")
                case .selector(let d):
                    XCTAssertEqual(n.stage, .selector, "seed \(seed) step \(step)")
                    XCTAssertEqual(n.decision, d, "seed \(seed) step \(step)")
                }
                if let id = n.decision.switchTo, n.stage == .selector {
                    new.focusRequested(id, at: t)
                    switches += 1
                }
                XCTAssertEqual(o.switched, n.stage == .selector ? n.decision.switchTo : nil, "seed \(seed) step \(step)")
                if n.burst?.fired == true { flicksFired += 1 }
                XCTAssertEqual(old.selector.current, new.selector.current, "seed \(seed) step \(step)")
                XCTAssertEqual(old.flickHoldUntil, new.flickHoldUntil, "seed \(seed) step \(step)")
                XCTAssertEqual(old.missionControlOpen, new.missionControlOpen, "seed \(seed) step \(step)")
                XCTAssertEqual(old.lastFrontWindow, new.lastFrontWindow, "seed \(seed) step \(step)")
                XCTAssertEqual(old.lastFocusRequestAt, new.lastFocusRequestAt, "seed \(seed) step \(step)")
                XCTAssertEqual(old.lastDecision, new.lastDecision, "seed \(seed) step \(step)")
                if testRun?.failureCount ?? 0 > 0 { return }
            }
            // The run has to exercise what it claims to.
            print("equivalence seed \(seed): \(switches) switches, \(flicksFired) flicks, \(mcCycles) Mission Control cycles, \(adopted) adoptions")
            XCTAssertGreaterThan(switches, 15, "seed \(seed)")
            XCTAssertGreaterThan(flicksFired, 0, "seed \(seed)")
            XCTAssertGreaterThan(mcCycles, 0, "seed \(seed)")
            XCTAssertGreaterThan(adopted, 0, "seed \(seed)")
        }
    }

    // MARK: Behaviour, directly

    /// yaw +10 maps into A, yaw −10 into B (pitch −8 keeps it in B's upper half, clear of C).
    private func sample(_ t: Double, yaw: Double, pitch: Double = -8, speed: Double = 1) -> HeadSample {
        HeadSample(yaw: yaw, pitch: pitch, speed: speed, deviceTime: t, hostTime: t)
    }

    /// Feed a still head for `seconds`; returns the first switch.
    private func hold(_ s: inout LiveSwitcher, yaw: Double, from t0: Double, seconds: Double, lastKey: Double = -100) -> (CGWindowID, Double)? {
        var t = t0
        while t < t0 + seconds {
            let h = sample(t, yaw: yaw)
            let pose = s.track(h, map: calibration.map)
            let step = s.decide(h, pose: pose, calibration: calibration, envelope: nil, yawAnchored: true, lastKeyDown: lastKey,
                                windows: windows, screensCG: [screen], gated: false)
            if let id = step.decision.switchTo { s.focusRequested(id, at: t); return (id, t) }
            t += 0.02
        }
        return nil
    }

    func testDwellSwitchThenAdoptsAClickElsewhereAfterASecond() throws {
        var s = LiveSwitcher()
        s.startTracking()
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: 0)
        XCTAssertEqual(s.selector.current, 1, "tracking adopts what is focused")
        let sw = try XCTUnwrap(hold(&s, yaw: -10, from: 0, seconds: 2))
        XCTAssertEqual(sw.0, 2)
        // Our request is in flight: a poll still showing A doesn't undo it.
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: sw.1 + 0.5)
        XCTAssertEqual(s.selector.current, 2)
        // A second later, A in front is the user's doing: adopt it. Not news for the log, though:
        // the earlier poll already saw A in front.
        let step = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: sw.1 + 1.2)
        XCTAssertEqual(s.selector.current, 1)
        XCTAssertNil(step.externalFocus)
        // ⌘-Tab to C, long after any request of ours: adopted and logged.
        let tab = s.windowsUpdated(windows, missionControlOpen: false, front: .window(3), active: true, now: sw.1 + 5)
        XCTAssertEqual(s.selector.current, 3)
        XCTAssertEqual(tab.externalFocus, 3)
    }

    func testAFailedRequestIsReplacedByWhatIsReallyInFront() throws {
        var s = LiveSwitcher()
        s.startTracking()
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: 0)
        let sw = try XCTUnwrap(hold(&s, yaw: -10, from: 0, seconds: 2))
        s.focusUnverified()
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: sw.1 + 0.2)
        XCTAssertEqual(s.selector.current, 1)
    }

    func testMissionControlHoldsThenAdoptsTheChosenWindowWithAHold() {
        var s = LiveSwitcher()
        s.startTracking()
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: 0)
        _ = s.windowsUpdated(windows, missionControlOpen: true, front: .window(1), active: true, now: 1)
        let h = sample(1.1, yaw: -10)
        let step = s.decide(h, pose: s.track(h, map: calibration.map), calibration: calibration, envelope: nil, yawAnchored: true,
                            lastKeyDown: -100, windows: windows, screensCG: [screen], gated: false)
        XCTAssertEqual(step.stage, .missionControl)
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(3), active: true, now: 2)
        XCTAssertEqual(s.selector.current, 3)
        XCTAssertEqual(s.flickHoldUntil, 2 + LiveSwitcher.missionControlHold, accuracy: 1e-9)
        // Still aimed where the thumbnail was (window 2): held, not pulled back.
        XCTAssertNil(hold(&s, yaw: -10, from: 2.7, seconds: 2))
    }

    func testGatedSamplesDecideNothing() {
        var s = LiveSwitcher()
        s.startTracking()
        _ = s.windowsUpdated(windows, missionControlOpen: false, front: .window(1), active: true, now: 0)
        var t = 0.0
        while t < 2 {
            let h = sample(t, yaw: -10)
            let step = s.decide(h, pose: s.track(h, map: calibration.map), calibration: calibration, envelope: nil, yawAnchored: true,
                                lastKeyDown: -100, windows: windows, screensCG: [screen], gated: true)
            XCTAssertEqual(step.stage, .gated)
            t += 0.02
        }
        XCTAssertEqual(s.selector.current, 1)
    }

    func testConfigureMatchesTheSensitivityTuning() {
        var s = LiveSwitcher()
        var c = LiveConfig()
        c.sensitivity = 1
        c.settingsHold = true
        s.configure(c)
        XCTAssertEqual(s.selector.config.dwell, SensitivityTuning.snappy.dwell, accuracy: 1e-12)
        XCTAssertFalse(s.selector.config.autoSwitch, "the Settings hold turns automatic switching off")
        c.settingsHold = false
        s.configure(c)
        XCTAssertTrue(s.selector.config.autoSwitch)
    }
}
