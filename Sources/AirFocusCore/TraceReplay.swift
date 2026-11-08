import CoreGraphics
import Foundation

/// What a trace says about the world so far: windows, focus, calibration, modes. The live replay
/// and the intent runner each keep one, built from the same events in the same order.
public struct TraceContext: Sendable {
    public private(set) var header: TraceHeader?
    public private(set) var windows: [TrackedWindow] = []
    public private(set) var screens: [CGRect] = []
    public private(set) var calibration: HeadCalibration?
    public private(set) var envelope: AngleEnvelope?
    public private(set) var front: LiveSwitcher.Front = .unknown
    public private(set) var missionControlOpen = false
    public private(set) var config = LiveConfig()
    public private(set) var lastKeyDown: TimeInterval = -.infinity
    public private(set) var yawNeedsRecenter = false
    public private(set) var settingsHold = false
    public private(set) var away = false
    public private(set) var obscured = false
    public private(set) var calibrating = false
    public private(set) var tracking = false

    public init() {}

    public var scene: IntentEngine.Scene? {
        calibration.map { IntentEngine.Scene(windows: windows, screensCG: screens, map: $0.map,
                                             lowestCalibratedPitch: $0.lowestCalibratedPitch) }
    }

    /// The tracked window really in front, where keys go.
    public var frontWindow: TrackedWindow? {
        guard case .window(let id) = front else { return nil }
        return windows.first { $0.id == id }
    }

    public mutating func apply(_ e: TraceEvent) {
        switch e {
        case .header(let h):
            header = h
            screens = h.screens
            calibration = h.calibration
            envelope = h.envelope
            front = h.state.current.map { .window($0) } ?? .unknown
            missionControlOpen = h.state.missionControl
            yawNeedsRecenter = !h.state.yawAnchored
            settingsHold = h.state.settingsHold
            away = h.state.away
            obscured = h.state.obscured
            calibrating = h.state.calibrating
            config.simulated = h.settings.simulated
            tracking = true
        case .windows(_, let ws):
            windows = ws.map(\.tracked)
        case .poll(_, let f, let mc):
            front = f
            missionControlOpen = mc
        case .key(let t):
            lastKeyDown = max(lastKeyDown, t)
        case .calibration(_, _, _, let cal):
            calibration = cal
            envelope = cal?.envelope(screensCG: screens)
        case .stream(_, .unanchored, _):
            yawNeedsRecenter = true
        case .stream(_, .anchored, _):
            yawNeedsRecenter = false
        case .mode(_, let kind, let on, _):
            switch kind {
            case .settings: settingsHold = on
            case .away: away = on
            case .obscured: obscured = on
            case .calibrating: calibrating = on
            default: break
            }
        case .config(_, let c):
            config = c
        case .tracking(_, let on):
            tracking = on
        case .display(_, _, let s):
            screens = s
            envelope = calibration?.envelope(screensCG: s)
        default:
            break
        }
    }
}

// MARK: - Live replay

/// Runs the live decision path over a trace, the way AppController runs it over real events.
public struct LiveReplayer: Sendable {
    public struct Output: Sendable {
        public var time: TimeInterval
        public var pose: LiveSwitcher.Pose
        public var step: LiveSwitcher.Step
        public var from: CGWindowID?
        public var switched: CGWindowID?
    }

    public private(set) var switcher = LiveSwitcher()
    public private(set) var context = TraceContext()

    public init() {}

    /// A file that starts in the middle of a session: pick up where its header says things stood.
    public mutating func resume(from h: TraceHeader) {
        switcher.sync(h.state.current)
    }

    public mutating func consume(_ e: TraceEvent) -> Output? {
        context.apply(e)
        switch e {
        case .config(_, let c):
            switcher.configure(c)
        case .tracking(_, true):
            switcher.startTracking()
        case .mode(_, .calibrating, true, _):
            switcher.resetFilter()
        case .calibration(_, .calibrated, _, _):
            switcher.calibrated()
        case .calibration(_, .recenter, let id, _), .calibration(_, .anchor, let id, _):
            switcher.sync(id)
        case .poll(let t, let front, let mc):
            _ = switcher.windowsUpdated(context.windows, missionControlOpen: mc, front: front,
                                        active: context.tracking && !context.calibrating, now: t)
        case .focusRequest(let t, let id, .hotkey):
            switcher.manualFocus(id, now: t)
            switcher.focusRequested(id, at: t)
        case .focusResult(_, _, false):
            switcher.focusUnverified()
        case .sample(let s):
            guard !s.flags.contains(.calibrating), !s.flags.contains(.uncalibrated), let cal = context.calibration else { return nil }
            let head = s.head
            let pose = switcher.track(head, map: cal.map)
            let from = switcher.selector.current
            let step = switcher.decide(head, pose: pose, calibration: cal, envelope: context.envelope,
                                       yawAnchored: !context.yawNeedsRecenter, lastKeyDown: context.lastKeyDown,
                                       windows: context.windows, screensCG: context.screens, gated: s.flags.contains(.gated))
            var out = Output(time: s.host, pose: pose, step: step, from: from)
            if let id = step.decision.switchTo {
                switcher.focusRequested(id, at: s.host)
                out.switched = id
            }
            return out
        default:
            break
        }
        return nil
    }
}

// MARK: - Intent runner

/// Feeds the intent engine from trace events: in the app (shadow mode, from the events as they're
/// recorded) and in a replay (from the file). Same events, same order, same answers.
public struct IntentRunner: Sendable {
    public enum Output: Equatable, Sendable {
        /// The engine would switch. `liveFront`: the window really in front; `liveAgrees`: live is
        /// there already or asked for it within the last second.
        case wouldSwitch(time: TimeInterval, from: CGWindowID?, to: CGWindowID, evidence: Double, threshold: Double,
                         phase: IntentEngine.Phase, typing: Bool, liveFront: CGWindowID?, liveAgrees: Bool)
        case note(time: TimeInterval, IntentEngine.Note)
        /// The shadow comparison over the last `summaryInterval` of tracking.
        case summary(String)
    }

    public static let summaryInterval: TimeInterval = 600

    public var engine: IntentEngine
    public private(set) var context = TraceContext()
    public private(set) var lastDecision = IntentEngine.Decision()
    /// The app logs a rolling comparison; a replay prints its own table instead.
    public var summaries: Bool
    private var flickHoldUntil: TimeInterval = -.infinity
    private var missionControlHoldUntil: TimeInterval = -.infinity
    private var adoptNextWithHold = false
    private var lastLiveRequest: (time: TimeInterval, id: CGWindowID)?
    private var shadow = ShadowTally()

    public init(parameters: IntentEngine.Parameters = .init(), summaries: Bool = false) {
        engine = IntentEngine(parameters: parameters)
        self.summaries = summaries
    }

    public mutating func consume(_ e: TraceEvent) -> [Output] {
        let wasMissionControl = context.missionControlOpen
        let previousCalibration = context.calibration
        context.apply(e)
        var out: [Output] = []
        switch e {
        case .tracking(let t, true):
            engine.startSession()
            flickHoldUntil = -.infinity
            missionControlHoldUntil = -.infinity
            adoptNextWithHold = false
            shadow.begin(at: t)
        case .poll(let t, let front, let mc):
            if wasMissionControl && !mc {
                missionControlHoldUntil = t + LiveSwitcher.missionControlHold
                adoptNextWithHold = true
            }
            if !mc, case .window(let id) = front {
                if adoptNextWithHold {
                    adoptNextWithHold = false
                    engine.adopt(id, at: t, hold: true)
                } else if engine.current == nil {
                    engine.adopt(id, at: t, hold: false)
                }
            }
        case .front(let t, let id?, .external):
            if id != engine.current { engine.adopt(id, at: t, hold: true) }
        case .focusRequest(let t, let id, .hotkey):
            engine.adopt(id, at: t, hold: false)
            lastLiveRequest = (t, id)
        case .focusRequest(let t, let id, .dwell):
            lastLiveRequest = (t, id)
            shadow.liveSwitch(at: t, to: id)
        case .key(let t):
            engine.keyDown(at: t, focused: context.frontWindow, scene: context.scene)
            shadow.key(at: t, window: context.frontWindow?.id)
        case .click(let t, _, let p, let id):
            engine.click(at: t, point: p, scene: context.scene)
            shadow.click(at: t, window: id)
        case .calibration(_, let kind, _, let cal):
            switch kind {
            case .calibrated, .reload: engine.calibrationReplaced()
            case .recenter: engine.recentered()
            case .nudge, .anchor:
                if let old = previousCalibration, let new = cal, let d = Self.shift(from: old.map, to: new.map) {
                    engine.mapShifted(yaw: d.yaw, pitch: d.pitch)
                } else {
                    engine.calibrationReplaced()
                }
            case .cleared: break
            }
        case .stream(_, .unanchored, _):
            engine.yawLost()
        case .flick(let t, let b) where b.fired:
            flickHoldUntil = t + LiveSwitcher.flickHold
        case .sample(let s):
            out += sample(s)
        default:
            break
        }
        for note in engine.drainNotes() { out.append(.note(time: e.time, note)) }
        return out
    }

    /// The live gates for this sample, as the intent engine sees them.
    public func gate(for s: TraceSample) -> IntentEngine.Gate? {
        if s.flags.contains(.calibrating) || context.calibrating { return .calibrating }
        if s.flags.contains(.uncalibrated) || context.calibration == nil || s.filteredYaw == nil { return .noCalibration }
        if s.flags.contains(.gated) { return .away }
        if context.missionControlOpen { return .missionControl }
        if s.host < flickHoldUntil || s.host < missionControlHoldUntil { return .flickHold }
        if context.settingsHold { return .settings }
        if !context.config.automatic { return .hotkeyOnly }
        return nil
    }

    private mutating func sample(_ s: TraceSample) -> [Output] {
        let gate = gate(for: s)
        guard gate != .calibrating, gate != .noCalibration, let fy = s.filteredYaw, let fp = s.filteredPitch else {
            lastDecision = IntentEngine.Decision(gate: gate)
            return []
        }
        let from = engine.current
        let d = engine.sample(time: s.host, yaw: fy, pitch: fp, speed: s.speed, scene: context.scene, gate: gate)
        lastDecision = d
        var out: [Output] = []
        if let to = d.switchTo {
            let liveFront: CGWindowID? = { if case .window(let id) = context.front { return id }; return nil }()
            let recent = lastLiveRequest.map { $0.id == to && s.host - $0.time <= 1.0 } ?? false
            out.append(.wouldSwitch(time: s.host, from: from, to: to, evidence: d.evidence, threshold: d.threshold,
                                    phase: d.phase, typing: s.host - context.lastKeyDown <= 1.5, liveFront: liveFront,
                                    liveAgrees: liveFront == to || recent))
            shadow.intentSwitch(at: s.host, to: to)
        }
        if summaries, let line = shadow.summary(at: s.host, every: Self.summaryInterval) { out.append(.summary(line)) }
        return out
    }

    /// The angle shift between two maps with the same linear part (a recenter, nudge or anchor).
    static func shift(from old: AffineHeadMap, to new: AffineHeadMap) -> (yaw: Double, pitch: Double)? {
        let same = zip(old.a.dropFirst(), new.a.dropFirst()).allSatisfy { abs($0 - $1) < 1e-9 }
            && zip(old.b.dropFirst(), new.b.dropFirst()).allSatisfy { abs($0 - $1) < 1e-9 }
        guard same else { return nil }
        return old.angleDelta(forScreenDelta: CGVector(dx: new.a[0] - old.a[0], dy: new.b[0] - old.b[0]))
    }
}

/// The app's rolling live-versus-intent comparison, one log line per ten minutes of tracking.
struct ShadowTally: Sendable {
    private var live: [SwitchMetrics.Switch] = []
    private var intent: [SwitchMetrics.Switch] = []
    private var liveFocus: CGWindowID?
    private var intentFocus: CGWindowID?
    private var keys: [SwitchMetrics.Key] = []
    private var clicks: [(time: TimeInterval, window: CGWindowID?)] = []
    private var windowStart: TimeInterval?
    private var tracked = 0.0
    private var lastSample: TimeInterval?

    mutating func begin(at t: TimeInterval) {
        if windowStart == nil { windowStart = t }
        lastSample = nil
    }

    mutating func liveSwitch(at t: TimeInterval, to id: CGWindowID) {
        live.append(SwitchMetrics.Switch(time: t, from: liveFocus, to: id))
        liveFocus = id
    }

    mutating func intentSwitch(at t: TimeInterval, to id: CGWindowID) {
        intent.append(SwitchMetrics.Switch(time: t, from: intentFocus, to: id))
        intentFocus = id
    }

    mutating func key(at t: TimeInterval, window: CGWindowID?) { keys.append(.init(time: t, window: window)) }
    mutating func click(at t: TimeInterval, window: CGWindowID?) { clicks.append((t, window)) }

    /// A summary once `every` of tracking has passed (time not tracking doesn't count), over the
    /// switches whose 3 s bounce window has closed.
    mutating func summary(at t: TimeInterval, every: TimeInterval) -> String? {
        tracked += lastSample.map { min(max(t - $0, 0), 0.25) } ?? 0
        lastSample = t
        guard let start = windowStart else { windowStart = t; return nil }
        guard tracked >= every else { return nil }
        let minutes = Int((tracked / 60).rounded())
        tracked = 0
        let end = t - SwitchMetrics.bounceWindow
        let l = SwitchMetrics.tally(live, from: start, to: end, keys: keys, clicks: clicks)
        let i = SwitchMetrics.tally(intent, from: start, to: end, keys: keys, clicks: clicks)
        let liveIn = live.filter { $0.time >= start && $0.time < end }
        let intentIn = intent.filter { $0.time >= start && $0.time < end }
        let matched = SwitchMetrics.matched(liveIn, intentIn)
        windowStart = end
        let keep = end - 10
        live.removeAll { $0.time < keep }
        intent.removeAll { $0.time < keep }
        keys.removeAll { $0.time < keep }
        clicks.removeAll { $0.time < keep }
        func part(_ name: String, _ r: SwitchMetrics.Tally) -> String {
            "\(name) \(r.switches) switch\(r.switches == 1 ? "" : "es"), \(r.bounces) bounced (\(SwitchMetrics.percent(r.bounces, r.switches))), "
                + "\(r.typing) while typing, \(r.late) late"
        }
        return "last \(minutes) min: " + part("live", l) + " · " + part("intent", i)
            + " · intent matched \(matched) of live's \(liveIn.count)"
    }
}

// MARK: - Metrics

/// Switching quality, the same way for every engine (spec §2.12). Bounce: a switch to B, then back to
/// A within 3 s with no key-down and no click in B in between. Typing: a key-down within 1.5 s both
/// before and after the switch, the one before typed before the head settled on B and not already
/// into B. Late: a key-down between the head settling on B and the switch, so keys went to the old
/// window (live's typing guard turns most of these into missed switches instead). Missed: a click,
/// ⌘-Tab or ⌃⌥⌘F into a window the head had been mapped onto for at least 1 s without the engine
/// switching. Latency: from the head settling on the target (under 25°/s, inside it) to the switch.
public struct SwitchMetrics: Sendable {
    public static let bounceWindow: TimeInterval = 3
    public static let typingWindow: TimeInterval = 1.5
    public static let missedAfter: TimeInterval = 1.0
    public static let settledSpeed = 25.0
    public static let matchWindow: TimeInterval = 1.5

    public struct Switch: Equatable, Sendable {
        public var time: TimeInterval
        public var from: CGWindowID?
        public var to: CGWindowID
        public var latency: Double?

        public init(time: TimeInterval, from: CGWindowID?, to: CGWindowID, latency: Double? = nil) {
            self.time = time; self.from = from; self.to = to; self.latency = latency
        }
    }

    /// A key-down and the window it really went to.
    public struct Key: Equatable, Sendable {
        public var time: TimeInterval
        public var window: CGWindowID?

        public init(time: TimeInterval, window: CGWindowID?) { self.time = time; self.window = window }
    }

    public struct Tally: Equatable, Sendable {
        public var switches = 0
        public var bounces = 0
        public var typing = 0
        public var late = 0
    }

    public private(set) var switches: [Switch] = []
    public private(set) var missed = 0
    public private(set) var seconds = 0.0
    private var hovered: CGWindowID?
    private var hoveredSince: TimeInterval = 0
    private var lastFast: TimeInterval = -.infinity

    public init() {}

    /// Every tracked sample: where this engine maps the head, and how fast it turns.
    public mutating func sampled(at t: TimeInterval, dt: Double, hovered h: CGWindowID?, speed: Double) {
        seconds += min(max(dt, 0), 0.25)
        if h != hovered { hovered = h; hoveredSince = t }
        if speed >= Self.settledSpeed { lastFast = t }
    }

    public mutating func switched(at t: TimeInterval, from: CGWindowID?, to: CGWindowID) {
        let latency = hovered == to ? max(0, t - max(hoveredSince, lastFast)) : nil
        switches.append(Switch(time: t, from: from, to: to, latency: latency))
    }

    /// The user focused `id` by hand while this engine had `current`.
    public mutating func explicitFocus(at t: TimeInterval, to id: CGWindowID, current: CGWindowID?) {
        if id != current, hovered == id, t - hoveredSince >= Self.missedAfter { missed += 1 }
    }

    public static func tally(_ s: [Switch], from start: TimeInterval = -.infinity, to end: TimeInterval = .infinity,
                             keys: [Key], clicks: [(time: TimeInterval, window: CGWindowID?)]) -> Tally {
        var r = Tally()
        for (i, sw) in s.enumerated() where sw.time >= start && sw.time < end {
            r.switches += 1
            if i + 1 < s.count {
                let next = s[i + 1]
                if let a = sw.from, next.to == a, next.from == sw.to, next.time - sw.time <= bounceWindow,
                   !keys.contains(where: { $0.time > sw.time && $0.time < next.time }),
                   !clicks.contains(where: { $0.time > sw.time && $0.time < next.time && $0.window == sw.to }) {
                    r.bounces += 1
                }
            }
            // Keys typed after the head settled on the target are the user getting on with it there:
            // a late switch, not one that interrupted typing.
            let settled = sw.time - (sw.latency ?? 0)
            if sw.latency.map({ $0 > 0 }) == true, keys.contains(where: { $0.time > settled && $0.time < sw.time }) {
                r.late += 1
            } else if let before = keys.last(where: { $0.time >= sw.time - typingWindow && $0.time <= settled }),
                      before.window != sw.to, keys.contains(where: { $0.time > sw.time && $0.time <= sw.time + typingWindow }) {
                r.typing += 1
            }
        }
        return r
    }

    /// Switches of `a` matched one-to-one by a switch of `b` to the same window within 1.5 s.
    public static func matched(_ a: [Switch], _ b: [Switch]) -> Int {
        var used = Array(repeating: false, count: b.count)
        var n = 0
        for x in a {
            var best: (Int, Double)?
            for (j, y) in b.enumerated() where !used[j] && y.to == x.to {
                let d = abs(y.time - x.time)
                if d <= matchWindow, d < (best?.1 ?? .infinity) { best = (j, d) }
            }
            if let (j, _) = best { used[j] = true; n += 1 }
        }
        return n
    }

    public static func percent(_ n: Int, _ of: Int) -> String {
        of == 0 ? "–" : "\(Int((Double(n) / Double(of) * 100).rounded()))%"
    }

    public static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

// MARK: - Replay

/// `--replay-trace`: both engines over recorded events, compared. Deterministic: no clocks, no
/// randomness, no dictionary order in anything it reports.
public struct TraceReplay: Sendable {
    public enum Engines: String, Sendable { case live, intent, both }

    public struct EngineReport: Sendable {
        public var switches: [SwitchMetrics.Switch] = []
        public var missed = 0
        public var seconds = 0.0
        public var tally = SwitchMetrics.Tally()

        public var latencies: [Double] { switches.compactMap(\.latency) }
        public var perHour: Double { seconds > 0 ? Double(switches.count) / (seconds / 3600) : 0 }
        public var bounceRate: Double { tally.switches > 0 ? Double(tally.bounces) / Double(tally.switches) : 0 }
        public var medianLatency: Double? { SwitchMetrics.median(latencies) }

        mutating func merge(_ o: EngineReport) {
            switches += o.switches
            missed += o.missed
            seconds += o.seconds
            tally.switches += o.tally.switches
            tally.bounces += o.tally.bounces
            tally.typing += o.tally.typing
            tally.late += o.tally.late
        }
    }

    public struct SessionReport: Sendable {
        public var label: String
        public var samples = 0
        public var keys: [SwitchMetrics.Key] = []
        public var clicks: [(time: TimeInterval, window: CGWindowID?)] = []
        public var live = EngineReport()
        public var intent = EngineReport()
        public var liveMatched = 0               // live switches matched by intent
        public var intentMatched = 0             // intent switches matched by live
        public var sameFocusSeconds = 0.0
        public var focusSeconds = 0.0
    }

    /// How closely the replayed live path matches what live actually did.
    public struct Fidelity: Sendable {
        public var recordedLive: [SwitchMetrics.Switch] = []
        public var replayedLive: [SwitchMetrics.Switch] = []
        public var recordedIntent: [SwitchMetrics.Switch] = []
        public var replayedIntent: [SwitchMetrics.Switch] = []
        public var maxFilterDelta = 0.0
        public var maxPointDelta = 0.0
        public var comparedSamples = 0
        public var recordedFlicks = 0
        public var replayedFlicks = 0
    }

    public let engines: Engines
    public let parameters: IntentEngine.Parameters
    public private(set) var sessions: [SessionReport] = []
    public private(set) var fidelity = Fidelity()
    public private(set) var files = 0
    public private(set) var skippedLines = 0
    public private(set) var events = 0

    private var live = LiveReplayer()
    private var intent: IntentRunner
    /// The recorded world, for where keys really went.
    private var world = TraceContext()
    private var liveMetrics = SwitchMetrics()
    private var intentMetrics = SwitchMetrics()
    private var session: SessionReport?
    private var lastSampleTime: TimeInterval?
    private var lastClick: TimeInterval = -.infinity
    private var lastHeader: TraceHeader?

    public init(engines: Engines = .both, parameters: IntentEngine.Parameters = .init()) {
        self.engines = engines
        self.parameters = parameters
        intent = IntentRunner(parameters: parameters)
    }

    private var runsLive: Bool { engines != .intent }
    private var runsIntent: Bool { engines != .live }

    /// One file's events, in order. Files of one session must come in order (their names sort so).
    public mutating func feed(_ list: [TraceEvent], skipped: Int = 0) {
        files += 1
        skippedLines += skipped
        for e in list { feed(e) }
    }

    public mutating func feed(_ e: TraceEvent) {
        events += 1
        if case .header(let h) = e { beginFile(h) }
        world.apply(e)
        if case .tracking(_, true) = e, session == nil { startSession(label: lastHeader?.session ?? "session") }

        // Explicit focus, checked against each engine before either adopts it.
        switch e {
        case .click(let t, _, _, let id?):
            lastClick = t
            explicitFocus(at: t, to: id)
        case .click(let t, _, _, nil):
            lastClick = t
        case .front(let t, let id?, .external) where t - lastClick > 0.7:
            explicitFocus(at: t, to: id)             // ⌘-Tab, Mission Control, or a click we didn't see
        case .focusRequest(let t, let id, .hotkey):
            explicitFocus(at: t, to: id)
        case .key(let t):
            session?.keys.append(.init(time: t, window: world.frontWindow?.id))
        default: break
        }
        if case .click(let t, _, _, let id) = e { session?.clicks.append((t, id)) }

        // Recorded decisions, for fidelity.
        switch e {
        case .focusRequest(let t, let id, .dwell): fidelity.recordedLive.append(.init(time: t, from: nil, to: id))
        case .intent(let t, let id, _, _): fidelity.recordedIntent.append(.init(time: t, from: nil, to: id))
        case .flick(_, let b) where b.fired: fidelity.recordedFlicks += 1
        default: break
        }

        var liveOut: LiveReplayer.Output?
        if runsLive { liveOut = live.consume(e) }
        var intentOut: [IntentRunner.Output] = []
        if runsIntent { intentOut = intent.consume(e) }

        if case .sample(let s) = e, !s.flags.contains(.calibrating), !s.flags.contains(.uncalibrated) {
            let dt = lastSampleTime.map { s.host - $0 } ?? 0
            lastSampleTime = s.host
            session?.samples += 1
            if let o = liveOut {
                if let f = s.filteredYaw, let g = s.filteredPitch, let p = s.point {
                    fidelity.comparedSamples += 1
                    fidelity.maxFilterDelta = max(fidelity.maxFilterDelta, abs(o.pose.yaw - f), abs(o.pose.pitch - g))
                    fidelity.maxPointDelta = max(fidelity.maxPointDelta, Geometry.distance(o.pose.point, p))
                }
                if o.step.burst?.fired == true { fidelity.replayedFlicks += 1 }
                let hovered = o.step.stage == .gated ? nil : WindowFilter.window(at: o.pose.point, in: live.context.windows)?.id
                liveMetrics.sampled(at: s.host, dt: dt, hovered: hovered, speed: s.speed)
                if let to = o.switched {
                    liveMetrics.switched(at: s.host, from: o.from, to: to)
                    fidelity.replayedLive.append(.init(time: s.host, from: o.from, to: to))
                }
            }
            if runsIntent {
                intentMetrics.sampled(at: s.host, dt: dt, hovered: intent.lastDecision.hovered, speed: s.speed)
                for case .wouldSwitch(let t, let from, let to, _, _, _, _, _, _) in intentOut {
                    intentMetrics.switched(at: t, from: from, to: to)
                    fidelity.replayedIntent.append(.init(time: t, from: from, to: to))
                }
                if runsLive, s.filteredYaw != nil {
                    let d = min(max(dt, 0), 0.25)
                    session?.focusSeconds += d
                    if live.switcher.selector.current == intent.engine.current { session?.sameFocusSeconds += d }
                }
            }
        }
        if case .tracking(_, false) = e { endSession() }
    }

    private mutating func beginFile(_ h: TraceHeader) {
        let continuing = lastHeader.map { $0.session == h.session && h.part == $0.part + 1 } ?? false
        if !continuing {
            endSession()
            // Each app launch starts with a fresh engine; within one, what it learned carries over.
            if lastHeader?.launch != h.launch { intent = IntentRunner(parameters: parameters) }
            live = LiveReplayer()
            if h.part > 1 { live.resume(from: h) }
            startSession(label: h.session + (h.part > 1 ? " part \(h.part)" : ""))
        }
        lastHeader = h
        lastSampleTime = nil
    }

    private mutating func startSession(label: String) {
        endSession()
        session = SessionReport(label: label)
        liveMetrics = SwitchMetrics()
        intentMetrics = SwitchMetrics()
    }

    private mutating func explicitFocus(at t: TimeInterval, to id: CGWindowID) {
        if runsLive { liveMetrics.explicitFocus(at: t, to: id, current: live.switcher.selector.current) }
        if runsIntent { intentMetrics.explicitFocus(at: t, to: id, current: intent.engine.current) }
    }

    private mutating func endSession() {
        guard var s = session else { return }
        session = nil
        func report(_ m: SwitchMetrics) -> EngineReport {
            var r = EngineReport()
            r.switches = m.switches
            r.missed = m.missed
            r.seconds = m.seconds
            r.tally = SwitchMetrics.tally(m.switches, keys: s.keys, clicks: s.clicks)
            return r
        }
        if runsLive { s.live = report(liveMetrics) }
        if runsIntent { s.intent = report(intentMetrics) }
        if runsLive && runsIntent {
            s.liveMatched = SwitchMetrics.matched(s.live.switches, s.intent.switches)
            s.intentMatched = SwitchMetrics.matched(s.intent.switches, s.live.switches)
        }
        if s.samples > 0 || !s.live.switches.isEmpty || !s.intent.switches.isEmpty { sessions.append(s) }
    }

    /// Ends the last session; call once after the last file.
    public mutating func finish() { endSession() }

    // MARK: Report

    public var total: SessionReport {
        var t = SessionReport(label: "all")
        for s in sessions {
            t.samples += s.samples
            t.keys += s.keys
            t.clicks += s.clicks
            t.live.merge(s.live)
            t.intent.merge(s.intent)
            t.liveMatched += s.liveMatched
            t.intentMatched += s.intentMatched
            t.sameFocusSeconds += s.sameFocusSeconds
            t.focusSeconds += s.focusSeconds
        }
        return t
    }

    public func table() -> String {
        var out: [String] = []
        let t = total
        let hours = max(t.live.seconds, t.intent.seconds) / 3600
        out.append(String(format: "Replayed %d file(s), %d session(s): %.2f h tracked, %d samples, %d key-downs, %d clicks%@",
                          files, sessions.count, hours, t.samples, t.keys.count, t.clicks.count,
                          skippedLines > 0 ? ", \(skippedLines) unreadable line(s) skipped" : ""))
        let changed = parameters.changes
        if !changed.isEmpty { out.append("intent parameters: \(changed)") }
        out.append("")

        var rows: [[String]] = [["", runsLive ? "live" : "", runsIntent ? "intent" : ""]]
        func row(_ name: String, _ f: (EngineReport) -> String) {
            rows.append([name, runsLive ? f(t.live) : "", runsIntent ? f(t.intent) : ""])
        }
        row("switches") { "\($0.switches.count)" }
        row("switches per hour") { String(format: "%.1f", $0.perHour) }
        row("bounces (A→B→A ≤ 3 s, no input in B)") { "\($0.tally.bounces) (\(SwitchMetrics.percent($0.tally.bounces, $0.tally.switches)))" }
        row("switches during a typing burst") { "\($0.tally.typing)" }
        row("late: keys typed after settling, before the switch") { "\($0.tally.late)" }
        row("probable missed switches") { "\($0.missed)" }
        row("median latency from settling") { r in r.medianLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "–" }
        out += Self.render(rows)

        if runsLive && runsIntent {
            out.append("")
            out.append("agreement: \(t.liveMatched) of live's \(t.live.switches.count) switches matched by intent (\(SwitchMetrics.percent(t.liveMatched, t.live.switches.count))), "
                       + "\(t.intentMatched) of intent's \(t.intent.switches.count) matched by live (\(SwitchMetrics.percent(t.intentMatched, t.intent.switches.count)))")
            if t.focusSeconds > 0 {
                out.append(String(format: "same focus %.0f%% of tracked time", t.sameFocusSeconds / t.focusSeconds * 100))
            }
        }

        if sessions.count > 1 {
            out.append("")
            var srows: [[String]] = [["session", "minutes", "live sw/bnc/typ/late/miss", "intent sw/bnc/typ/late/miss", "latency live/intent"]]
            for s in sessions {
                func cell(_ r: EngineReport, _ on: Bool) -> String {
                    on ? "\(r.switches.count)/\(r.tally.bounces)/\(r.tally.typing)/\(r.tally.late)/\(r.missed)" : ""
                }
                func ms(_ r: EngineReport, _ on: Bool) -> String {
                    on ? (r.medianLatency.map { String(format: "%.0f", $0 * 1000) } ?? "–") : ""
                }
                srows.append([s.label, String(format: "%.1f", max(s.live.seconds, s.intent.seconds) / 60),
                              cell(s.live, runsLive), cell(s.intent, runsIntent), "\(ms(s.live, runsLive))/\(ms(s.intent, runsIntent)) ms"])
            }
            out += Self.render(srows)
        }

        out.append("")
        out.append("replay fidelity:")
        let f = fidelity
        if runsLive {
            let matchedLive = Self.exactMatches(f.recordedLive, f.replayedLive, within: 0.1)
            out.append("  live: recorded \(f.recordedLive.count) dwell switch(es), replayed \(f.replayedLive.count), "
                       + "\(matchedLive) matched within 100 ms (\(SwitchMetrics.percent(matchedLive, max(f.recordedLive.count, f.replayedLive.count))))")
            out.append(String(format: "  live: filtered pose within %.4f°, mapped point within %.2f pt of the recording over %d samples",
                              f.maxFilterDelta, f.maxPointDelta, f.comparedSamples))
            out.append("  live: recorded \(f.recordedFlicks) fired flick(s), replayed \(f.replayedFlicks)")
            if let first = Self.firstDivergence(f.recordedLive, f.replayedLive, within: 0.1) {
                out.append(String(format: "  live: first divergence at host time %.3f", first))
            }
        }
        if runsIntent {
            if f.recordedIntent.isEmpty {
                out.append("  intent: no shadow decisions in the recording to compare")
            } else {
                let m = Self.exactMatches(f.recordedIntent, f.replayedIntent, within: 0.001)
                out.append("  intent: recorded \(f.recordedIntent.count) shadow switch(es), replayed \(f.replayedIntent.count), \(m) identical"
                           + (changed.isEmpty ? "" : " (parameters differ from the recording's)"))
            }
        }
        return out.joined(separator: "\n")
    }

    static func render(_ rows: [[String]]) -> [String] {
        let widths = (0..<(rows.first?.count ?? 0)).map { c in rows.map { $0[c].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { i, cell in
                i == 0 ? cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                       : String(repeating: " ", count: widths[i] - cell.count) + cell
            }.joined(separator: "   ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    /// One-to-one matches with the same target within `within` seconds.
    public static func exactMatches(_ a: [SwitchMetrics.Switch], _ b: [SwitchMetrics.Switch], within: Double) -> Int {
        var j = 0, n = 0
        var used = Array(repeating: false, count: b.count)
        for x in a {
            while j < b.count && b[j].time < x.time - within { j += 1 }
            var k = j
            while k < b.count && b[k].time <= x.time + within {
                if !used[k] && b[k].to == x.to { used[k] = true; n += 1; break }
                k += 1
            }
        }
        return n
    }

    static func firstDivergence(_ a: [SwitchMetrics.Switch], _ b: [SwitchMetrics.Switch], within: Double) -> TimeInterval? {
        for (i, x) in a.enumerated() {
            guard i < b.count else { return x.time }
            if b[i].to != x.to || abs(b[i].time - x.time) > within { return min(x.time, b[i].time) }
        }
        return b.count > a.count ? b[a.count].time : nil
    }
}
