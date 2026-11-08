import CoreGraphics
import Foundation

/// Synthetic session traces for tests and `--synthesize-trace`: a simulated user and head, and the
/// app's live path running on them, recorded the way the app records. Realistic enough to exercise
/// both engines; it proves nothing about real use, which only real traces can.
///
/// The head: minimum-jerk movements that turn only part of the way to the gaze (the eyes do the
/// rest), slow sway while fixating, sensor noise, and optional drift of the yaw zero. The user: reads,
/// types in bursts, glances, clicks, and clicks back into the window they meant when keys went astray.
public enum TraceSynthesizer {
    public enum Scenario: String, CaseIterable, Sendable {
        case typingGlances          // typing in A, glancing at B and back
        case driftWhileTyping       // yaw drifting slowly across the A/B boundary while typing in A
        case cleanSwitches          // deliberate turns to another window, then typing there
        case boundaryJitter         // reading at the A/B edge, the pointer jittering across it
        case clicksWithDrift        // a stale calibration offset; clicks show where the user looks
        case restartThenClick       // a stream restart, then a click before any typing
        case settleWithoutTyping    // turning to a window and reading it, no typing
    }

    /// Every scenario in one trace: one session (header) each, as consecutive tracking sessions.
    /// The intent engine runs in shadow over the whole thing, as in the app, and its decisions go in.
    public static func events(_ scenarios: [Scenario] = Scenario.allCases, seed: UInt64 = 7,
                              intent: IntentEngine.Parameters = .init()) -> [TraceEvent] {
        var rng = SplitMix64(seed: seed)
        var runner = IntentRunner(parameters: intent)
        var out: [TraceEvent] = []
        var start = 1000.0
        for scenario in scenarios {
            var sim = Simulation(plan: Plan.make(scenario, start: start, rng: &rng), rng: rng)
            let events = sim.run()
            rng = sim.rng
            for e in events {
                out.append(e)
                for case .wouldSwitch(let t, _, let to, let evidence, let threshold, _, _, _, _) in runner.consume(e) {
                    out.append(.intent(t, to, evidence: evidence, threshold: threshold))
                }
            }
            start = (events.last?.time ?? start) + 30
        }
        return out
    }

    /// The file's text, as the recorder would write it.
    public static func text(_ events: [TraceEvent]) -> String {
        ([TraceFormat.banner] + events.map(\.line)).joined(separator: "\n") + "\n"
    }

    // MARK: World

    static let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    /// 64 pt per degree of yaw, 60 per degree of pitch, a little cross-talk; −12° pitch is mid-screen.
    static let map = AffineHeadMap(a: [1280 + 3 * -12, -64, 3], b: [-2 * 0, -2, -60])
    static let calibration: HeadCalibration = {
        let points = [CGPoint(x: 1280, y: 720), CGPoint(x: 384, y: 216), CGPoint(x: 2176, y: 216),
                      CGPoint(x: 384, y: 1224), CGPoint(x: 2176, y: 1224)]
        let samples = points.compactMap { p in map.angles(for: p).map { CalibrationSample(yaw: $0.yaw, pitch: $0.pitch, screen: p) } }
        return HeadCalibration(map: map, samples: samples, anchors: [], displayKey: "synthetic@0,0,2560x1440",
                               createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }()

    static func window(_ id: CGWindowID, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> TrackedWindow {
        TrackedWindow(id: id, pid: Int32(id), appName: "com.example.term\(id)", bundleID: "com.example.term\(id)",
                      frameCG: CGRect(x: x, y: y, width: w, height: h), visibleRects: [CGRect(x: x, y: y, width: w, height: h)],
                      visibleFraction: 1, targetPointCG: CGPoint(x: x + w / 2, y: y + h / 2))
    }

    static let twoUp = [window(11, 0, 25, 1280, 1415), window(12, 1280, 25, 1280, 1415)]
    static let threeUp = [window(21, 0, 25, 1280, 1415), window(22, 1280, 25, 1280, 707), window(23, 1280, 732, 1280, 708)]

    // MARK: Plans

    struct Plan {
        var scenario: Scenario
        var start: Double
        var duration: Double
        var windows: [TrackedWindow]
        var gaze: [(time: Double, point: CGPoint)] = []
        var keys: [Double] = []
        var clicks: [(time: Double, point: CGPoint)] = []
        /// The window the user means keys to go to, from each time on.
        var intended: [(time: Double, id: CGWindowID)] = []
        var headGain = 0.85
        var staleOffset = (yaw: 0.0, pitch: 0.0)
        var driftPerSecond = 0.0             // yaw, degrees: the pointer creeps right for negative values
        var restartYawJump: Double?
        var bias = (x: 0.0, y: 0.0)          // where the head rests aims: the gaze, pulled towards this

        var end: Double { start + duration }

        func intended(at t: Double) -> CGWindowID? { intended.last { $0.time <= t }?.id }

        static func make(_ s: Scenario, start: Double, rng: inout SplitMix64) -> Plan {
            switch s {
            case .typingGlances: return typingGlances(start, &rng)
            case .driftWhileTyping: return driftWhileTyping(start, &rng)
            case .cleanSwitches: return cleanSwitches(start, &rng)
            case .boundaryJitter: return boundaryJitter(start, &rng)
            case .clicksWithDrift: return clicksWithDrift(start, &rng)
            case .restartThenClick: return restartThenClick(start, &rng)
            case .settleWithoutTyping: return settleWithoutTyping(start, &rng)
            }
        }

        /// Fixations at random reading points inside `w` from `from` to `to`.
        mutating func read(_ w: TrackedWindow, from: Double, to: Double, _ rng: inout SplitMix64, inset: Double = 0.12,
                           region: CGRect? = nil) {
            var t = from
            while t < to {
                gaze.append((t, rng.point(in: region ?? w.frameCG.insetBy(dx: w.frameCG.width * inset, dy: w.frameCG.height * inset))))
                t += rng.uniform(0.9, 3.0)
            }
        }

        /// Key-downs at about 6 a second, with the odd hesitation.
        mutating func type(from: Double, to: Double, _ rng: inout SplitMix64) {
            var t = from
            while t < to {
                keys.append(t)
                t += 0.06 + rng.exponential(0.11) + (rng.uniform(0, 1) < 0.06 ? rng.uniform(0.25, 0.6) : 0)
            }
        }

        static func typingGlances(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let a = twoUp[0], b = twoUp[1]
            var p = Plan(scenario: .typingGlances, start: start, duration: 180, windows: twoUp)
            p.intended = [(start, a.id)]
            var t = start + 0.5
            while t < p.end - 6 {
                let typing = rng.uniform(5, 10)
                p.read(a, from: t, to: t + typing, &rng)
                p.type(from: t + 0.3, to: t + typing, &rng)
                // A pause, a look at B, back to A, typing resumes.
                let look = t + typing + rng.uniform(0.05, 0.3)
                let dwell = rng.uniform(0.5, 1.6)
                p.gaze.append((look, rng.point(in: b.frameCG.insetBy(dx: 200, dy: 250))))
                t = look + dwell
                p.gaze.append((t, rng.point(in: a.frameCG.insetBy(dx: 200, dy: 250))))
                // Straight back to typing, or a moment reading A first.
                t += rng.uniform(0, 1) < 0.5 ? rng.uniform(0.15, 0.5) : rng.uniform(0.6, 2.0)
            }
            return p
        }

        static func driftWhileTyping(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let a = twoUp[0]
            var p = Plan(scenario: .driftWhileTyping, start: start, duration: 180, windows: twoUp)
            p.intended = [(start, a.id)]
            p.driftPerSecond = -4.0 / 60          // the pointer creeps right, into B, 4° a minute
            p.read(a, from: start + 0.5, to: p.end, &rng, region: CGRect(x: 640, y: 200, width: 560, height: 1000))
            var t = start + 1
            while t < p.end - 2 {
                let burst = rng.uniform(3, 8)
                p.type(from: t, to: min(t + burst, p.end), &rng)
                t += burst + rng.uniform(0.5, 2.5)
            }
            return p
        }

        static func cleanSwitches(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let ws = threeUp
            var p = Plan(scenario: .cleanSwitches, start: start, duration: 180, windows: ws)
            var current = 0
            var t = start + 0.5
            p.intended = [(start, ws[0].id)]
            while t < p.end - 8 {
                let w = ws[current]
                let stay = rng.uniform(3, 7)
                p.read(w, from: t, to: t + stay, &rng, inset: 0.2)
                p.type(from: t + rng.uniform(0.6, 1.0), to: t + stay, &rng)
                // Finish typing, glance over the output, then turn.
                t += stay + rng.uniform(0.5, 2.5)
                current = (current + 1 + Int(rng.uniform(0, 1.999))) % ws.count
                p.intended.append((t, ws[current].id))
            }
            return p
        }

        static func boundaryJitter(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let a = twoUp[0]
            var p = Plan(scenario: .boundaryJitter, start: start, duration: 120, windows: twoUp)
            p.intended = [(start, a.id)]
            p.headGain = 1.0
            // Reading along A's right edge, up to 1.25° either side of it.
            var t = start + 0.5
            while t < p.end {
                p.gaze.append((t, CGPoint(x: rng.uniform(1200, 1360), y: rng.uniform(300, 1100))))
                t += rng.uniform(0.6, 2.2)
            }
            var k = start + 4
            while k < p.end - 3 {
                p.type(from: k, to: k + rng.uniform(0.8, 2), &rng)
                k += rng.uniform(8, 16)
            }
            return p
        }

        static func clicksWithDrift(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let ws = threeUp
            var p = Plan(scenario: .clicksWithDrift, start: start, duration: 180, windows: ws)
            p.staleOffset = (3.5, -1.5)           // the pointer sits 220 pt left of and 90 pt below the gaze
            var current = 0
            var t = start + 0.5
            p.intended = [(start, ws[0].id)]
            while t < p.end - 8 {
                let w = ws[current]
                let stay = rng.uniform(4, 8)
                p.read(w, from: t, to: t + stay, &rng, inset: 0.2)
                if rng.uniform(0, 1) < 0.6 {
                    // The point is decided when it happens: wherever the user is looking.
                    p.clicks.append((t + rng.uniform(0.7, 1.2), .zero))
                }
                p.type(from: t + rng.uniform(1.3, 1.8), to: t + stay, &rng)
                t += stay + rng.uniform(0.4, 1.0)
                current = (current + 1 + Int(rng.uniform(0, 1.999))) % ws.count
                p.intended.append((t, ws[current].id))
            }
            return p
        }

        static func restartThenClick(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let a = twoUp[0], b = twoUp[1]
            var p = Plan(scenario: .restartThenClick, start: start, duration: 120, windows: twoUp)
            p.restartYawJump = 17
            p.intended = [(start, a.id), (start + 2.5, b.id)]
            p.read(a, from: start + 0.3, to: start + 2.5, &rng, inset: 0.25)
            p.gaze.append((start + 2.5, CGPoint(x: 1900, y: 650)))
            p.clicks.append((start + 3.6, .zero))
            p.type(from: start + 4.2, to: start + 8, &rng)
            var t = start + 8.5
            var onB = true
            while t < p.end - 6 {
                let w = onB ? a : b
                onB.toggle()
                p.intended.append((t, w.id))
                let stay = rng.uniform(4, 8)
                p.read(w, from: t, to: t + stay, &rng, inset: 0.2)
                p.type(from: t + rng.uniform(0.7, 1.1), to: t + stay, &rng)
                t += stay + rng.uniform(0.4, 1.0)
            }
            return p
        }

        static func settleWithoutTyping(_ start: Double, _ rng: inout SplitMix64) -> Plan {
            let ws = threeUp
            var p = Plan(scenario: .settleWithoutTyping, start: start, duration: 120, windows: ws)
            var current = 0
            var t = start + 0.5
            p.intended = [(start, ws[0].id)]
            while t < p.end - 6 {
                p.read(ws[current], from: t, to: t + rng.uniform(2.5, 5), &rng, inset: 0.2)
                t = p.gaze.last!.time + rng.uniform(1.5, 3)
                current = (current + 1 + Int(rng.uniform(0, 1.999))) % ws.count
                p.intended.append((t, ws[current].id))
            }
            return p
        }
    }

    // MARK: Simulation

    struct Simulation {
        let plan: Plan
        var rng: SplitMix64
        var events: [TraceEvent] = []
        static let dt = 0.02

        // The app.
        var live = LiveSwitcher()
        var calibration = TraceSynthesizer.calibration
        var envelope = TraceSynthesizer.calibration.envelope(screensCG: [TraceSynthesizer.screen])
        var config = LiveConfig()
        var yawNeedsRecenter = false
        var recentKeyDowns: [Double] = []
        var lastKeyDown = -Double.infinity
        var stillSince: Double?
        var lastPose: (yaw: Double, pitch: Double, point: CGPoint, time: Double)?
        var implicit = ImplicitRecenterPolicy()
        var lastReject: TargetSelector.Reject??
        var lastRequest: (time: Double, id: CGWindowID)?

        // The world.
        var front: CGWindowID?
        var recordedFront: CGWindowID??
        var focusArrives: (time: Double, id: CGWindowID)?
        var results: [(time: Double, id: CGWindowID)] = []
        var dropKeysUntil = -Double.infinity
        var wrongKeys = 0
        var corrections: [(time: Double, id: CGWindowID)] = []

        // The head, in the calibrated frame (degrees).
        var aim = (yaw: 0.0, pitch: -12.0)
        var move: (from: (yaw: Double, pitch: Double), to: (yaw: Double, pitch: Double), start: Double, duration: Double)?
        var sway = (yaw: 0.0, pitch: 0.0)
        var gazePoint = CGPoint(x: 1280, y: 720)
        var previous: (yaw: Double, pitch: Double)?

        init(plan: Plan, rng: SplitMix64) {
            self.plan = plan
            self.rng = rng
        }

        /// Where the head points for a gaze point: part of the way from the screen centre.
        func headAim(for gaze: CGPoint) -> (yaw: Double, pitch: Double) {
            let g = plan.headGain
            let p = CGPoint(x: 1280 + g * (gaze.x - 1280), y: 720 + g * (gaze.y - 720))
            return TraceSynthesizer.map.angles(for: p) ?? (0, -12)
        }

        mutating func emit(_ e: TraceEvent) { events.append(e) }

        mutating func run() -> [TraceEvent] {
            let start = plan.start
            let windows = plan.windows
            front = plan.intended(at: start)
            if let g = plan.gaze.first { gazePoint = g.point; aim = headAim(for: g.point) }
            yawNeedsRecenter = plan.restartYawJump != nil

            var state = TraceState()
            state.current = front
            state.yawAnchored = !yawNeedsRecenter
            let settings = TraceSettings()
            emit(.header(TraceHeader(app: "synthetic", launch: "synthetic", session: plan.scenario.rawValue, part: 1,
                                     started: "2026-11-07T00:00:00Z", uptime: start, displayKey: calibration.displayKey,
                                     screens: [TraceSynthesizer.screen], calibration: calibration, settings: settings, state: state)))
            emit(.tracking(start, true))
            live.startTracking()
            config.switchingPaused = yawNeedsRecenter
            live.configure(config)
            emit(.config(start, config))
            if plan.restartYawJump != nil {
                emit(.stream(start, .restarted, "synthetic restart"))
                emit(.stream(start, .unanchored, "motion stream restarted"))
            }

            var gazeIndex = 0, keyIndex = 0, clickIndex = 0
            var nextPoll = start
            var t = start
            var first = true
            while t < plan.end {
                t += Simulation.dt + rng.uniform(-0.001, 0.001)
                let host = t + 0.004 + rng.uniform(0, 0.002)

                // Gaze changes start a head movement shortly after the eyes.
                while gazeIndex < plan.gaze.count && plan.gaze[gazeIndex].time <= t {
                    gazePoint = plan.gaze[gazeIndex].point
                    var target = headAim(for: gazePoint)
                    target.yaw += rng.normal() * 0.8
                    target.pitch += rng.normal() * 0.5
                    let from = currentAim(at: t)
                    let amplitude = hypot(target.yaw - from.yaw, target.pitch - from.pitch)
                    move = (from, target, plan.gaze[gazeIndex].time + 0.05, 0.16 + 0.011 * amplitude)
                    gazeIndex += 1
                }

                // Things that happen between samples, in time order.
                while true {
                    let key = keyIndex < plan.keys.count ? plan.keys[keyIndex] : .infinity
                    let click = clickIndex < plan.clicks.count ? plan.clicks[clickIndex].time : .infinity
                    let correction = corrections.first?.time ?? .infinity
                    let pollTime = nextPoll
                    let soonest = min(key, click, correction, pollTime)
                    guard soonest <= host else { break }
                    if soonest == pollTime {
                        nextPoll += 0.125
                        poll(at: pollTime, windows: windows, first: first)
                        first = false
                    } else if soonest == correction {
                        let c = corrections.removeFirst()
                        clickAt(c.time, inWindow: c.id, windows: windows)
                    } else if soonest == click {
                        clickIndex += 1
                        clickAt(click, inWindow: nil, windows: windows)
                    } else {
                        keyIndex += 1
                        keyDown(at: key, windows: windows)
                    }
                }

                let pose = rawPose(at: t)
                sample(HeadSample(yaw: pose.yaw, pitch: pose.pitch, speed: pose.speed, deviceTime: t, hostTime: host),
                       windows: windows)
            }
            emit(.tracking(plan.end, false))
            emit(.end(plan.end))
            return events
        }

        func currentAim(at t: Double) -> (yaw: Double, pitch: Double) {
            guard let m = move else { return aim }
            let s = min(1, max(0, (t - m.start) / m.duration))
            let e = s * s * s * (10 - 15 * s + 6 * s * s)
            return (m.from.yaw + (m.to.yaw - m.from.yaw) * e, m.from.pitch + (m.to.pitch - m.from.pitch) * e)
        }

        /// The raw pose the AirPods report: aim, sway, the stale offset and drift, an arbitrary yaw
        /// zero after a restart, and noise. Speed is the true angular rate plus gyro noise.
        mutating func rawPose(at t: Double) -> (yaw: Double, pitch: Double, speed: Double) {
            if let m = move, t >= m.start + m.duration { aim = m.to; move = nil }
            let a = currentAim(at: t)
            let tau = 0.8, sigma = plan.scenario == .boundaryJitter ? 0.45 : 0.3
            let k = (2 * Simulation.dt / tau).squareRoot() * sigma
            sway.yaw += -sway.yaw * Simulation.dt / tau + k * rng.normal()
            sway.pitch += -sway.pitch * Simulation.dt / tau + k * rng.normal() * 0.6
            let yaw = a.yaw + sway.yaw, pitch = a.pitch + sway.pitch
            let speed = previous.map { hypot(yaw - $0.yaw, pitch - $0.pitch) / Simulation.dt } ?? 0
            previous = (yaw, pitch)
            let drift = plan.driftPerSecond * (t - plan.start)
            return (yaw + plan.staleOffset.yaw + drift + (plan.restartYawJump ?? 0) + rng.normal() * 0.03,
                    pitch + plan.staleOffset.pitch + rng.normal() * 0.03,
                    abs(speed + rng.normal() * 1.5))
        }

        // MARK: The app, as AppController runs it

        mutating func sample(_ s: HeadSample, windows: [TrackedWindow]) {
            let now = s.hostTime
            let pose = live.track(s, map: calibration.map)
            if s.speed < 10 { stillSince = stillSince ?? now } else { stillSince = nil }
            lastPose = (pose.yaw, pose.pitch, pose.point, now)
            let step = live.decide(s, pose: pose, calibration: calibration, envelope: envelope,
                                   yawAnchored: !yawNeedsRecenter, lastKeyDown: lastKeyDown, windows: windows,
                                   screensCG: [TraceSynthesizer.screen], gated: false)
            if let b = step.burst, b.fired || b.peakRate >= 100 { emit(.flick(now, b)) }
            if step.stage == .selector {
                if let id = step.decision.switchTo {
                    live.focusRequested(id, at: now)
                    lastRequest = (now, id)
                    emit(.focusRequest(now, id, .dwell))
                    focusArrives = (now + 0.09, id)
                    results.append((now + 0.15, id))
                }
                if lastReject != .some(step.decision.reject) {
                    lastReject = .some(step.decision.reject)
                    emit(.reject(now, step.decision.reject))
                }
            }
            emit(.sample(TraceSample(s, filtered: (pose.yaw, pose.pitch), point: pose.point)))
        }

        mutating func poll(at t: Double, windows: [TrackedWindow], first: Bool) {
            if let f = focusArrives, f.time <= t { front = f.id; focusArrives = nil }
            while let r = results.first, r.time <= t {
                results.removeFirst()
                emit(.focusResult(r.time, r.id, verified: true))
            }
            if first { emit(.windows(t, windows.map(TraceWindow.init))) }
            let f: LiveSwitcher.Front = front.map { .window($0) } ?? .unknown
            emit(.poll(t, front: f, missionControl: false))
            if recordedFront != .some(front) {
                if recordedFront != nil {
                    let ours = lastRequest.map { $0.id == front && t - $0.time < 2 } ?? false
                    emit(.front(t, front, ours ? .request : .external))
                }
                recordedFront = .some(front)
            }
            _ = live.windowsUpdated(windows, missionControlOpen: false, front: f, active: true, now: t)
        }

        mutating func keyDown(at t: Double, windows: [TrackedWindow]) {
            guard t > dropKeysUntil else { return }
            // Keys into the wrong window: the user notices after a couple, stops and clicks the right one.
            if let want = plan.intended(at: t), front != want {
                wrongKeys += 1
                if wrongKeys >= 2 && corrections.isEmpty {
                    dropKeysUntil = t + 0.6
                    corrections.append((t + rng.uniform(0.35, 0.55), want))
                }
            } else {
                wrongKeys = 0
            }
            emit(.key(t))
            lastKeyDown = t
            recentKeyDowns.append(t)
            recentKeyDowns.removeAll { t - $0 > 2.0 }
            if yawNeedsRecenter { return autoAnchor(at: t, windows: windows) }
            guard let pose = lastPose, let still = stillSince, t - pose.time < 0.5,
                  let focused = windows.first(where: { $0.id == front }),
                  implicit.shouldNudge(point: pose.point, focused: focused, windows: windows, settledFor: t - still, now: t)
            else { return }
            var cal = calibration
            let applied = cal.nudge(yaw: pose.yaw, pitch: pose.pitch, towards: focused.targetPointCG,
                                    fraction: implicit.fraction, maxDegrees: implicit.maxDegreesPerEvent)
            implicit.noteApplied(degrees: applied, now: t)
            calibration = cal
            envelope = cal.envelope(screensCG: [TraceSynthesizer.screen])
            emit(.calibration(t, .nudge, nil, cal))
        }

        mutating func autoAnchor(at t: Double, windows: [TrackedWindow]) {
            guard let pose = lastPose, t - pose.time < 0.5, let still = stillSince, t - still >= 1.5,
                  recentKeyDowns.count >= 3, let focused = windows.first(where: { $0.id == front }) else { return }
            var cal = calibration
            _ = cal.reanchorYaw(yaw: pose.yaw, pitch: pose.pitch, onto: focused.targetPointCG)
            calibration = cal
            envelope = cal.envelope(screensCG: [TraceSynthesizer.screen])
            emit(.calibration(t, .anchor, focused.id, cal))
            yawNeedsRecenter = false
            emit(.stream(t, .anchored, "typing"))
            config.switchingPaused = false
            live.configure(config)
            emit(.config(t, config))
            implicit.resetBudget()
            live.sync(focused.id)
            recentKeyDowns.removeAll()
        }

        mutating func clickAt(_ t: Double, inWindow id: CGWindowID?, windows: [TrackedWindow]) {
            // Where the user is looking, or the middle of the window they mean if they're looking elsewhere.
            var p = gazePoint
            if let id, let w = windows.first(where: { $0.id == id }), !w.visibleContains(p) { p = w.targetPointCG }
            let hit = WindowFilter.window(at: p, in: windows)?.id
            emit(.click(t, .left, p, hit))
            if let hit { front = hit; focusArrives = nil }
            wrongKeys = 0
        }
    }
}

/// A small deterministic generator (SplitMix64), so a seed always makes the same trace.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [a, b).
    public mutating func uniform(_ a: Double, _ b: Double) -> Double {
        a + (b - a) * Double(next() >> 11) / Double(1 << 53)
    }

    public mutating func normal() -> Double {
        let u = max(uniform(0, 1), 1e-12), v = uniform(0, 1)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    public mutating func exponential(_ mean: Double) -> Double { -mean * log(max(uniform(0, 1), 1e-12)) }

    public mutating func point(in r: CGRect) -> CGPoint {
        CGPoint(x: uniform(Double(r.minX), Double(r.maxX)), y: uniform(Double(r.minY), Double(r.maxY)))
    }
}
