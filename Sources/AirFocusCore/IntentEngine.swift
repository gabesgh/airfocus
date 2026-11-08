import CoreGraphics
import Foundation

/// Intent-based switching (spec §2.11), in shadow mode: it watches what the live selector watches,
/// plus key-downs, clicks and modes, and says when it *would* switch. It never focuses anything.
///
/// Instead of a fixed dwell it accumulates evidence: each sample, every window gets a likelihood
/// from the angular distance between the corrected head pointer and the window's visible region,
/// and each candidate gathers a leaky log-likelihood ratio against the current window. How the head
/// moved weights that evidence, typing and a habit of reference glances raise the bar, and its own
/// model of how this user's head relates to the calibrated map (an offset that drifts, and a gain,
/// since the eyes do part of the work) corrects the pointer. Pure and deterministic: the app and
/// `--replay-trace` feed it the same events and get the same answers.
public struct IntentEngine: Sendable {
    public struct Parameters: Equatable, Sendable {
        // Likelihood: head pointer ~ gaze target in the window + N(0, σ) per axis, in degrees.
        public var sigma = 2.5                 // starting σ; clicks refine it
        public var sigmaMin = 1.0
        public var sigmaMax = 5.0
        public var sigmaLearning = 0.1         // EWMA weight of one click residual
        public var likelihoodFloor = 0.02      // caps one sample's log-likelihood ratio at about ±4
        // Evidence: dE/dt = rate · weight · LLR − E / leak; switch at E ≥ threshold × multipliers.
        public var rate = 10.0
        public var leak = 2.0
        public var threshold = 15.0
        public var evidenceFloor = -3.0
        public var cooldown = 0.3
        // Movement shape.
        public var movingSpeed = 25.0          // °/s: no evidence while the head turns (live's gate)
        public var shiftSpeed = 40.0           // °/s: a burst this fast is a deliberate shift
        public var settleSpeed = 15.0          // °/s: below this the head has settled...
        public var settleTime = 0.08           // ...for this long
        public var shiftMinDegrees = 3.0
        public var postShiftSeconds = 2.0      // a fixation this soon after a shift counts fully
        public var postShiftWeight = 1.0
        public var farShiftBoost = 2.0         // extra weight for a shift of farShiftDegrees or more
        public var farShiftDegrees = 15.0
        public var settledWeight = 0.4         // settled, but no shift brought it here
        public var creepWeight = 0.15          // slow continuous movement: drift
        public var creepDegreesPerSecond = 1.0
        public var creepWindow = 0.6
        // Typing: the bar rises steeply while typing and falls back over a few seconds.
        public var typingFactor = 4.0
        public var typingFullSeconds = 0.3
        public var typingDecaySeconds = 3.0
        public var typingAcceptKeys = 3.0      // this many keys into the candidate: the user accepted it
        public var typingBurstGap = 0.6        // a longer pause between keys ends a burst
        // Reference glances: B looked at and left while typing into A.
        public var glanceExtra = 3.0           // the bar rises by up to this much more...
        public var glanceHalf = 2.0            // ...half of it after this many glances
        public var glanceMaxSeconds = 3.0
        public var glanceConfirmSeconds = 2.0  // typing must resume this soon after the return
        public var glanceHalfLife = 1800.0
        // The head model: offset (drifts) and gain (how far the head turns for the gaze), per axis.
        public var driftPerMinute = 1.0        // σ of the offset's random walk over a minute, degrees
        public var offsetSigmaMax = 8.0
        public var gainSigma = 0.15            // prior spread of the gain around 1
        public var gainMin = 0.5
        public var gainMax = 1.3
        public var clickSeconds = 0.3          // median pose over this long before a click...
        public var clickMaxSpeed = 20.0        // ...with the head settled
        public var clickMaxResidual = 8.0      // people sometimes click without looking
        public var clickSigma = 1.5
        public var typingSigma = 5.0           // one-sided and weak
        public var typingSettleSeconds = 0.5
        public var typingInterval = 1.0
        public var anchorKeys = 3.0            // a burst this big with a still head anchors an unknown yaw
        public var anchorWindow = 2.0
        public var anchorSettledSeconds = 1.0
        public var recenterSigma = 1.0
        public var calibrationSigma = 1.5
        // The live selector's rejects.
        public var keyboardGlanceDegrees = 10.0
        public var offScreenMargin = 150.0

        public init() {}

        /// Every parameter by name, for `--set name=value`.
        public static let names: [(String, WritableKeyPath<Parameters, Double>)] = [
            ("sigma", \.sigma), ("sigmaMin", \.sigmaMin), ("sigmaMax", \.sigmaMax), ("sigmaLearning", \.sigmaLearning),
            ("likelihoodFloor", \.likelihoodFloor), ("rate", \.rate), ("leak", \.leak), ("threshold", \.threshold),
            ("evidenceFloor", \.evidenceFloor), ("cooldown", \.cooldown), ("movingSpeed", \.movingSpeed),
            ("shiftSpeed", \.shiftSpeed), ("settleSpeed", \.settleSpeed), ("settleTime", \.settleTime),
            ("shiftMinDegrees", \.shiftMinDegrees), ("postShiftSeconds", \.postShiftSeconds),
            ("postShiftWeight", \.postShiftWeight), ("farShiftBoost", \.farShiftBoost), ("farShiftDegrees", \.farShiftDegrees),
            ("settledWeight", \.settledWeight), ("creepWeight", \.creepWeight),
            ("creepDegreesPerSecond", \.creepDegreesPerSecond), ("creepWindow", \.creepWindow),
            ("typingFactor", \.typingFactor), ("typingFullSeconds", \.typingFullSeconds),
            ("typingDecaySeconds", \.typingDecaySeconds), ("typingAcceptKeys", \.typingAcceptKeys),
            ("typingBurstGap", \.typingBurstGap),
            ("glanceExtra", \.glanceExtra), ("glanceHalf", \.glanceHalf),
            ("glanceMaxSeconds", \.glanceMaxSeconds), ("glanceConfirmSeconds", \.glanceConfirmSeconds),
            ("glanceHalfLife", \.glanceHalfLife), ("driftPerMinute", \.driftPerMinute), ("offsetSigmaMax", \.offsetSigmaMax),
            ("gainSigma", \.gainSigma), ("gainMin", \.gainMin), ("gainMax", \.gainMax),
            ("clickSeconds", \.clickSeconds), ("clickMaxSpeed", \.clickMaxSpeed), ("clickMaxResidual", \.clickMaxResidual),
            ("clickSigma", \.clickSigma), ("typingSigma", \.typingSigma), ("typingSettleSeconds", \.typingSettleSeconds),
            ("typingInterval", \.typingInterval), ("anchorKeys", \.anchorKeys), ("anchorWindow", \.anchorWindow),
            ("anchorSettledSeconds", \.anchorSettledSeconds), ("recenterSigma", \.recenterSigma),
            ("calibrationSigma", \.calibrationSigma), ("keyboardGlanceDegrees", \.keyboardGlanceDegrees),
            ("offScreenMargin", \.offScreenMargin),
        ]

        /// "name=value,name=value". Returns the first pair it can't read, or nil when all applied.
        public mutating func apply(overrides: String) -> String? {
            for pair in overrides.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let path = Self.names.first(where: { $0.0 == kv[0] })?.1,
                      let v = Double(kv[1]), v.isFinite else { return String(pair) }
                self[keyPath: path] = v
            }
            return nil
        }

        /// The values that differ from the defaults, for a report.
        public var changes: String {
            let d = Parameters()
            return Self.names.filter { self[keyPath: $0.1] != d[keyPath: $0.1] }
                .map { "\($0.0)=\(self[keyPath: $0.1])" }.joined(separator: ",")
        }
    }

    /// The live gates, plus the engine's own (no calibration).
    public enum Gate: String, Sendable {
        case missionControl, flickHold, away, calibrating, settings, hotkeyOnly, noCalibration, keyboardGlance, offScreen
    }

    /// How the head is moving, which sets how much a sample's evidence counts.
    public enum Phase: String, Sendable {
        case moving        // turning: nothing counts
        case shift         // settled after a deliberate shift: counts fully
        case settled       // still, with no shift that brought it here
        case creep         // slow continuous drift: counts little
    }

    /// What the targeting sees.
    public struct Scene: Sendable {
        public var windows: [TrackedWindow]      // front to back
        public var screensCG: [CGRect]
        public var map: AffineHeadMap
        public var lowestCalibratedPitch: Double?

        public init(windows: [TrackedWindow], screensCG: [CGRect], map: AffineHeadMap, lowestCalibratedPitch: Double?) {
            self.windows = windows; self.screensCG = screensCG; self.map = map
            self.lowestCalibratedPitch = lowestCalibratedPitch
        }

        /// The middle of the screens in map angles: the head model's gain pivots here.
        var centre: (yaw: Double, pitch: Double) {
            let u = Geometry.union(screensCG)
            return u.isNull ? (0, 0) : (map.angles(for: CGPoint(x: u.midX, y: u.midY)) ?? (0, 0))
        }
    }

    public struct Decision: Equatable, Sendable {
        /// The engine would focus this window now.
        public var switchTo: CGWindowID?
        /// The window under the corrected pointer; nil while yaw is unknown.
        public var hovered: CGWindowID?
        public var point: CGPoint?
        public var gate: Gate?
        public var phase = Phase.settled
        /// The leading candidate, its evidence and the bar it has to clear.
        public var candidate: CGWindowID?
        public var evidence = 0.0
        public var threshold = 0.0
    }

    /// Things worth a log line.
    public enum Note: Equatable, Sendable {
        case clickAnchoredYaw(residualPitch: Double)
        case typingAnchoredYaw
        case clickRejected(residual: Double)
        case clickMeasured(residual: Double)
    }

    /// One axis of the head model: the pose u relates to the map angle v of what the user looks at by
    /// u − c = α + β (v − c), with c the screens' centre. α drifts; β is the head's share of the turn.
    /// A two-state Kalman filter; while yaw is unknown its α variance is effectively infinite.
    public struct Axis: Equatable, Sendable {
        public static let unknown = 1e6
        public private(set) var alpha = 0.0
        public private(set) var beta = 1.0
        var p00: Double
        var p01 = 0.0
        var p11: Double

        init(variance: Double, gainSigma: Double) {
            p00 = variance
            p11 = gainSigma * gainSigma
        }

        public var known: Bool { p00 < Self.unknown / 10 }
        public var offsetVariance: Double { p00 }

        /// The map angle the user looks at, given the pose.
        func corrected(_ u: Double, centre c: Double) -> Double { c + (u - c - alpha) / beta }

        /// The variance of `corrected` from the model's own uncertainty.
        func variance(at v: Double, centre c: Double) -> Double {
            let d = v - c
            return max(0, p00 + 2 * d * p01 + d * d * p11) / (beta * beta)
        }

        func residual(u: Double, v: Double, centre c: Double) -> Double { (u - c) - alpha - beta * (v - c) }

        mutating func predict(_ q: Double, cap: Double) {
            if known { p00 = min(cap, p00 + q) }
        }

        mutating func update(u: Double, v: Double, centre c: Double, measurementVariance r: Double, learnGain: Bool,
                             gainRange: ClosedRange<Double>) {
            let h1 = learnGain ? v - c : 0
            let e = residual(u: u, v: v, centre: c)
            let ph0 = p00 + p01 * h1, ph1 = p01 + p11 * h1
            let s = ph0 + h1 * ph1 + r
            guard s > 0 else { return }
            let k0 = ph0 / s, k1 = ph1 / s
            alpha += k0 * e
            beta = min(gainRange.upperBound, max(gainRange.lowerBound, beta + k1 * e))
            let n00 = p00 - k0 * ph0, n01 = p01 - k0 * ph1, n11 = p11 - k1 * ph1
            p00 = max(n00, 1e-6); p01 = n01; p11 = max(n11, 1e-6)
        }

        /// The pose u looks at v, exactly enough to trust with `variance`.
        mutating func anchor(u: Double, v: Double, centre c: Double, variance: Double) {
            alpha = (u - c) - beta * (v - c)
            p00 = variance
            p01 = 0
        }

        mutating func reset(variance: Double) { alpha = 0; p00 = variance; p01 = 0 }
        mutating func lose() { p00 = Self.unknown; p01 = 0 }
        mutating func shift(_ d: Double) { alpha += d }
    }

    private struct Record: Sendable { var t: TimeInterval; var yaw: Double; var pitch: Double; var speed: Double }
    private struct Key: Sendable { var t: TimeInterval; var window: CGWindowID? }
    private struct Glance: Sendable { var from: CGWindowID; var to: CGWindowID; var at: TimeInterval }
    private struct Habit: Sendable { var from: CGWindowID; var to: CGWindowID; var count: Double; var at: TimeInterval }

    public var parameters: Parameters
    public private(set) var current: CGWindowID?
    public private(set) var notes: [Note] = []

    private var evidence: [CGWindowID: Double] = [:]
    private var lastTime: TimeInterval?
    private var lastSwitch: TimeInterval = -.infinity
    private var holdArmed = false
    private var holdWindow: CGWindowID?

    // Movement shape.
    private var history: [Record] = []
    private var inMotion = false
    private var motionStart: (yaw: Double, pitch: Double)?
    private var motionPeak = 0.0
    private var quietFor = 0.0
    private var motionStartedAt: TimeInterval = -.infinity
    private var shiftStartedAt: TimeInterval = -.infinity
    private var shiftSettledAt: TimeInterval = -.infinity
    private var shiftAmplitude = 0.0
    private var stillSince: TimeInterval?
    private var jitterVariance = 0.0
    private var lastJitterAt: TimeInterval = -.infinity

    // Noise and the head model.
    public private(set) var sigma: Double
    public private(set) var yaw: Axis
    public private(set) var pitch: Axis
    private var lastTypingMeasure: TimeInterval = -.infinity

    // Typing and glances.
    public private(set) var lastKeyDown: TimeInterval = -.infinity
    private var keys: [Key] = []
    private var lastSettledHovered: CGWindowID?
    private var glance: Glance?
    private var glanceReturn: Glance?
    /// This engine's last switch, in case the head undoes it: a glance it fell for.
    private var undoable: Glance?
    private var habits: [Habit] = []

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
        sigma = parameters.sigma
        let v = parameters.calibrationSigma * parameters.calibrationSigma
        yaw = Axis(variance: v, gainSigma: parameters.gainSigma)
        pitch = Axis(variance: v, gainSigma: parameters.gainSigma)
    }

    /// Yaw has a known zero: the head model means something along it.
    public var yawKnown: Bool { yaw.known }

    public mutating func drainNotes() -> [Note] {
        defer { notes.removeAll() }
        return notes
    }

    private var gainRange: ClosedRange<Double> { parameters.gainMin...max(parameters.gainMin, parameters.gainMax) }

    // MARK: Session

    /// Tracking started: decisions start over; what was learned about the user stays.
    public mutating func startSession() {
        current = nil
        evidence.removeAll()
        lastTime = nil
        lastSwitch = -.infinity
        holdArmed = false
        holdWindow = nil
        history.removeAll()
        inMotion = false
        shiftStartedAt = -.infinity
        shiftSettledAt = -.infinity
        stillSince = nil
        glance = nil
        glanceReturn = nil
        undoable = nil
        lastSettledHovered = nil
    }

    /// Focus moved for a reason other than this engine: a click, ⌘-Tab, ⌃⌥⌘F, Mission Control.
    /// `hold`: the head may be aimed elsewhere, so don't pull focus back to where it points until it moves.
    public mutating func adopt(_ id: CGWindowID?, at t: TimeInterval, hold: Bool) {
        if let from = current, let to = id, from != to { weakenHabit(from: from, to: to) }
        current = id
        evidence.removeAll()
        glance = nil
        glanceReturn = nil
        if let u = undoable, id == u.from, t - u.at <= parameters.glanceMaxSeconds {
            glanceReturn = Glance(from: u.from, to: u.to, at: t)
        }
        undoable = nil
        holdArmed = hold && id != nil
        holdWindow = nil
        if hold { lastSwitch = t }
    }

    // MARK: The head model

    /// A stream restart, reference jump or return from look-away: the yaw zero is arbitrary now.
    public mutating func yawLost() {
        yaw.lose()
        evidence.removeAll()
    }

    /// ⌃⌥⌘R: the user looked at the focused window and the live map now points there exactly.
    public mutating func recentered() {
        let v = parameters.recenterSigma * parameters.recenterSigma
        yaw.reset(variance: v)
        pitch.reset(variance: v)
    }

    /// A fresh calibration replaced the live map. The gain is the user's, so it stays.
    public mutating func calibrationReplaced() {
        let v = parameters.calibrationSigma * parameters.calibrationSigma
        yaw.reset(variance: v)
        pitch.reset(variance: v)
    }

    /// The live map moved by δ (a nudge or an anchor: map'(v) = map(v + δ)). The engine keeps its own
    /// model, so it re-expresses it against the new map instead of taking the correction.
    public mutating func mapShifted(yaw dy: Double, pitch dp: Double) {
        yaw.shift(dy)
        pitch.shift(dp)
    }

    // MARK: Input

    /// A key went down. `focused` is the window really in front, where the key went.
    public mutating func keyDown(at t: TimeInterval, focused: TrackedWindow?, scene: Scene?) {
        let p = parameters
        lastKeyDown = t
        keys.append(Key(t: t, window: focused?.id))
        keys.removeAll { t - $0.t > p.typingDecaySeconds + 1 }
        if let r = glanceReturn, t - r.at <= p.glanceConfirmSeconds {
            noteGlance(from: r.from, to: r.to, at: t)
            glanceReturn = nil
        }
        guard let focused, let scene, let last = history.last, t - last.t < 0.25, let still = stillSince else { return }
        let settled = t - still
        let c = scene.centre
        if !yawKnown {
            // Typing into a window with a still head: the user is looking at it. Weak, but enough to start.
            let burst = keys.filter { t - $0.t <= p.anchorWindow }.count
            guard Double(burst) >= p.anchorKeys, settled >= p.anchorSettledSeconds,
                  let target = scene.map.angles(for: focused.targetPointCG) else { return }
            let halfWidth = abs(scene.map.angleDelta(forScreenDelta: CGVector(dx: focused.frameCG.width / 2, dy: 0))?.yaw ?? 5)
            yaw.anchor(u: last.yaw, v: target.yaw, centre: c.yaw, variance: max(p.clickSigma * p.clickSigma, halfWidth * halfWidth / 3))
            evidence.removeAll()
            lastTypingMeasure = t
            notes.append(.typingAnchoredYaw)
            return
        }
        // One-sided: typing says the head is somewhere in the focused window, so it only pulls
        // when the pointer has drifted outside it. It moves the offset, never the gain.
        guard settled >= p.typingSettleSeconds, t - lastTypingMeasure >= p.typingInterval else { return }
        let point = pointer(yaw: last.yaw, pitch: last.pitch, scene: scene)
        guard !focused.visibleContains(point), let inside = Self.nearestInside(point, focused),
              let target = scene.map.angles(for: inside) else { return }
        let ry = yaw.residual(u: last.yaw, v: target.yaw, centre: c.yaw)
        let rp = pitch.residual(u: last.pitch, v: target.pitch, centre: c.pitch)
        guard hypot(ry, rp) <= p.clickMaxResidual else { return }
        let r = p.typingSigma * p.typingSigma
        yaw.update(u: last.yaw, v: target.yaw, centre: c.yaw, measurementVariance: r, learnGain: false, gainRange: gainRange)
        pitch.update(u: last.pitch, v: target.pitch, centre: c.pitch, measurementVariance: r, learnGain: false, gainRange: gainRange)
        lastTypingMeasure = t
    }

    /// A mouse button went down at `point`: the user looks where they click.
    public mutating func click(at t: TimeInterval, point: CGPoint, scene: Scene?) {
        let p = parameters
        guard let scene, let target = scene.map.angles(for: point) else { return }
        let window = history.filter { $0.t >= t - p.clickSeconds && $0.t <= t + 1e-6 }
        guard window.count >= 5, window.allSatisfy({ $0.speed < p.clickMaxSpeed }) else { return }
        let u = (yaw: Self.median(window.map(\.yaw)), pitch: Self.median(window.map(\.pitch)))
        let c = scene.centre
        let r = p.clickSigma * p.clickSigma
        let rp = pitch.residual(u: u.pitch, v: target.pitch, centre: c.pitch)
        if !yawKnown {
            guard abs(rp) <= p.clickMaxResidual else { return notes.append(.clickRejected(residual: abs(rp))) }
            yaw.anchor(u: u.yaw, v: target.yaw, centre: c.yaw, variance: r)
            pitch.update(u: u.pitch, v: target.pitch, centre: c.pitch, measurementVariance: r, learnGain: true, gainRange: gainRange)
            evidence.removeAll()
            notes.append(.clickAnchoredYaw(residualPitch: rp))
            return
        }
        let ry = yaw.residual(u: u.yaw, v: target.yaw, centre: c.yaw)
        let residual = hypot(ry, rp)
        guard residual <= p.clickMaxResidual else { return notes.append(.clickRejected(residual: residual)) }
        // The residual's spread, less what the model's own uncertainty explains, is the head-to-gaze noise.
        let explained = (yaw.variance(at: target.yaw, centre: c.yaw) + pitch.variance(at: target.pitch, centre: c.pitch)) / 2
        let observed = max(p.sigmaMin * p.sigmaMin, (ry * ry + rp * rp) / 2 - explained)
        let s2 = (1 - p.sigmaLearning) * sigma * sigma + p.sigmaLearning * observed
        sigma = min(p.sigmaMax, max(p.sigmaMin, s2.squareRoot()))
        yaw.update(u: u.yaw, v: target.yaw, centre: c.yaw, measurementVariance: r, learnGain: true, gainRange: gainRange)
        pitch.update(u: u.pitch, v: target.pitch, centre: c.pitch, measurementVariance: r, learnGain: true, gainRange: gainRange)
        notes.append(.clickMeasured(residual: residual))
    }

    /// Where the user is looking, by the head model, for a live filtered pose.
    public func pointer(yaw u: Double, pitch w: Double, scene: Scene) -> CGPoint {
        let c = scene.centre
        return scene.map.point(yaw: yaw.corrected(u, centre: c.yaw), pitch: pitch.corrected(w, centre: c.pitch))
    }

    // MARK: Samples

    /// One sample of the live filtered pose. `gate` is set when a live gate holds switching.
    public mutating func sample(time t: TimeInterval, yaw u: Double, pitch w: Double, speed: Double, scene: Scene?,
                                gate liveGate: Gate?) -> Decision {
        let p = parameters
        let dt = lastTime.map { min(max(t - $0, 0), 0.1) } ?? 0
        lastTime = t
        let q = p.driftPerMinute * p.driftPerMinute / 60 * dt
        let cap = p.offsetSigmaMax * p.offsetSigmaMax
        yaw.predict(q, cap: cap)
        pitch.predict(q, cap: cap)

        history.append(Record(t: t, yaw: u, pitch: w, speed: speed))
        if let i = history.firstIndex(where: { t - $0.t <= 1.0 }), i > 0 { history.removeFirst(i) }
        if speed < 10 { stillSince = stillSince ?? t } else { stillSince = nil }
        let phase = updatePhase(t: t, dt: dt, yaw: u, pitch: w, speed: speed)
        updateJitter(t: t)
        if let s = undoable, t - s.at > p.glanceMaxSeconds {
            // The switch stuck: a real switch weakens any glance habit for the pair.
            weakenHabit(from: s.from, to: s.to)
            undoable = nil
        }

        var d = Decision(phase: phase)
        guard let scene else {
            clearEvidence()
            d.gate = liveGate ?? .noCalibration
            return d
        }
        let c = scene.centre
        let cy = yaw.corrected(u, centre: c.yaw), cp = pitch.corrected(w, centre: c.pitch)
        let point = scene.map.point(yaw: cy, pitch: cp)
        d.point = point
        let hovered = yawKnown ? WindowFilter.window(at: point, in: scene.windows)?.id : nil
        d.hovered = hovered
        if speed < p.movingSpeed { trackGlances(t: t, hovered: hovered) }

        if let liveGate { clearEvidence(); d.gate = liveGate; return d }
        if let low = scene.lowestCalibratedPitch, cp < low - p.keyboardGlanceDegrees {
            clearEvidence(); d.gate = .keyboardGlance; return d
        }
        if yawKnown, Geometry.distance(from: point, toAnyOf: scene.screensCG) > p.offScreenMargin {
            clearEvidence(); d.gate = .offScreen; return d
        }

        // Likelihood of each window, and evidence for each candidate against the current window.
        let sy = (sigma * sigma + jitterVariance + yaw.variance(at: cy, centre: c.yaw)).squareRoot()
        let sp = (sigma * sigma + jitterVariance + pitch.variance(at: cp, centre: c.pitch)).squareRoot()
        let geometry = AngleGeometry(map: scene.map)
        var likelihood: [Double] = []
        likelihood.reserveCapacity(scene.windows.count)
        for win in scene.windows {
            let z = yawKnown ? geometry.signedDistance(point, win, sigmaYaw: sy, sigmaPitch: sp)
                             : geometry.signedPitchDistance(cp, win, sigmaPitch: sp)
            likelihood.append(Self.phi(-z))
        }
        let currentIndex = current.flatMap { id in scene.windows.firstIndex { $0.id == id } }
        let lCurrent = currentIndex.map { likelihood[$0] } ?? (current == nil ? 0.5 : 0)
        let weight = self.weight(phase, t: t)
        let decay = exp(-dt / max(p.leak, 1e-3))
        let floor = p.likelihoodFloor
        var next: [CGWindowID: Double] = [:]
        for (i, win) in scene.windows.enumerated() where win.id != current {
            let llr = log(likelihood[i] + floor) - log(lCurrent + floor)
            next[win.id] = max(p.evidenceFloor, (evidence[win.id] ?? 0) * decay + weight * llr * p.rate * dt)
        }
        evidence = next

        // An adopted focus change: the window the head was on stays blocked until the head moves.
        if holdArmed {
            if hovered == current {
                holdArmed = false
            } else if let h = hovered {
                if holdWindow == nil { holdWindow = h }
                if holdWindow == h { evidence[h] = min(evidence[h] ?? 0, 0) } else { holdArmed = false }
            }
        }

        // The leader, front to back so ties are deterministic.
        var best: (id: CGWindowID, e: Double)?
        for win in scene.windows {
            if let e = evidence[win.id], e > (best?.e ?? -.infinity) { best = (win.id, e) }
        }
        guard let best else { return d }
        let threshold = p.threshold * typingMultiplier(t, candidate: best.id) * glanceMultiplier(from: current, to: best.id, t: t)
        d.candidate = best.id
        d.evidence = best.e
        d.threshold = threshold
        guard best.e >= threshold, t - lastSwitch >= p.cooldown else { return d }
        // Switching straight back is the head undoing a switch: it was a glance after all.
        let undone = undoable.flatMap { u in u.from == best.id && u.to == current && t - u.at <= p.glanceMaxSeconds ? u : nil }
        undoable = current.map { Glance(from: $0, to: best.id, at: t) }
        glanceReturn = undone.map { Glance(from: $0.from, to: $0.to, at: t) }
        if undone != nil { undoable = nil }
        current = best.id
        lastSwitch = t
        evidence.removeAll()
        glance = nil
        holdArmed = false
        d.switchTo = best.id
        return d
    }

    private mutating func clearEvidence() {
        if !evidence.isEmpty { evidence.removeAll() }
    }

    /// Shift detection from the raw gyro speed: a burst that peaks at `shiftSpeed` or more and then
    /// settles is a deliberate shift; its fixation counts fully for a while.
    private mutating func updatePhase(t: TimeInterval, dt: Double, yaw u: Double, pitch w: Double, speed: Double) -> Phase {
        let p = parameters
        if speed >= p.settleSpeed {
            if !inMotion {
                inMotion = true
                motionStart = history.count >= 2 ? (history[history.count - 2].yaw, history[history.count - 2].pitch) : (u, w)
                motionStartedAt = t
                motionPeak = 0
            }
            motionPeak = max(motionPeak, speed)
            quietFor = 0
        } else if inMotion {
            quietFor += dt
            if quietFor >= p.settleTime {
                inMotion = false
                let start = motionStart ?? (u, w)
                let amplitude = hypot(u - start.yaw, w - start.pitch)
                if motionPeak >= p.shiftSpeed && amplitude >= p.shiftMinDegrees {
                    shiftStartedAt = motionStartedAt
                    shiftSettledAt = t
                    shiftAmplitude = amplitude
                }
            }
        }
        if speed >= p.movingSpeed { return .moving }
        if t - shiftSettledAt <= p.postShiftSeconds { return .shift }
        // Creep: the pose keeps moving slowly, without any burst.
        if let old = history.first(where: { t - $0.t <= p.creepWindow }), t - old.t >= p.creepWindow * 0.8 {
            let rate = hypot(u - old.yaw, w - old.pitch) / max(t - old.t, 1e-3)
            if rate >= p.creepDegreesPerSecond { return .creep }
        }
        return .settled
    }

    private func weight(_ phase: Phase, t: TimeInterval) -> Double {
        let p = parameters
        switch phase {
        case .moving: return 0
        case .creep: return p.creepWeight
        case .settled: return p.settledWeight
        case .shift:
            let far = min(1, max(0, (shiftAmplitude - p.shiftMinDegrees) / max(p.farShiftDegrees - p.shiftMinDegrees, 1e-3)))
            let full = p.postShiftWeight * (1 + p.farShiftBoost * far)
            // Fades to the settled weight over the second half of the window.
            let age = (t - shiftSettledAt) / max(p.postShiftSeconds, 1e-3)
            let fade = age <= 0.5 ? 1 : max(0, 1 - (age - 0.5) / 0.5)
            return p.settledWeight + (full - p.settledWeight) * fade
        }
    }

    /// The jitter of the filtered pose during settled fixations: a floor under σ.
    private mutating func updateJitter(t: TimeInterval) {
        guard let still = stillSince, t - still >= 0.3, t - lastJitterAt >= 0.3 else { return }
        let window = history.filter { t - $0.t <= 0.3 }
        guard window.count >= 5 else { return }
        lastJitterAt = t
        func variance(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(v.count)
            return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
        }
        let v = (variance(window.map(\.yaw)) + variance(window.map(\.pitch))) / 2
        jitterVariance = jitterVariance == 0 ? v : 0.95 * jitterVariance + 0.05 * v
    }

    // MARK: Typing and glances

    /// How much harder typing makes a switch to `candidate`: `typingFactor` at the last key, falling
    /// back to 1 over `typingDecaySeconds`. During the fixation a deliberate shift started, a burst
    /// that begins after the turn doesn't count: that's the user getting on with it in the new window.
    /// Typing that carries straight on through the turn does: that's typing in A while looking at B.
    /// Keys that went into the candidate itself (in shadow mode, where live already put focus) mean
    /// the user accepted it, once there are a few.
    public func typingMultiplier(_ t: TimeInterval, candidate: CGWindowID?) -> Double {
        let p = parameters
        let accepted = candidate.map { c in Double(keys.filter { $0.window == c && t - $0.t <= 2 }.count) >= p.typingAcceptKeys } ?? false
        var cutoff = TimeInterval.infinity
        if t - shiftSettledAt <= p.postShiftSeconds, let after = keys.first(where: { $0.t > shiftStartedAt }) {
            let before = keys.last { $0.t <= shiftStartedAt }
            if before.map({ after.t - $0.t > p.typingBurstGap }) ?? true { cutoff = shiftStartedAt }
        }
        guard let last = keys.last(where: { $0.t <= cutoff && (!accepted || $0.window != candidate) })?.t else { return 1 }
        let since = t - last
        if since <= p.typingFullSeconds { return p.typingFactor }
        if since >= p.typingDecaySeconds { return 1 }
        let tau = max(p.typingDecaySeconds - p.typingFullSeconds, 1e-3) / 3
        return 1 + (p.typingFactor - 1) * exp(-(since - p.typingFullSeconds) / tau)
    }

    public func glanceMultiplier(from: CGWindowID?, to: CGWindowID, t: TimeInterval) -> Double {
        guard let from, let h = habits.first(where: { $0.from == from && $0.to == to }) else { return 1 }
        let count = decayed(h, t)
        return 1 + parameters.glanceExtra * count / (count + max(parameters.glanceHalf, 1e-3))
    }

    /// Reference glances seen for the pair, decayed to `t`.
    public func glanceCount(from: CGWindowID, to: CGWindowID, at t: TimeInterval) -> Double {
        habits.first { $0.from == from && $0.to == to }.map { decayed($0, t) } ?? 0
    }

    private func decayed(_ h: Habit, _ t: TimeInterval) -> Double {
        h.count * pow(0.5, max(0, t - h.at) / max(parameters.glanceHalfLife, 1))
    }

    /// A real switch to B is the opposite of a reference glance at it.
    private mutating func weakenHabit(from: CGWindowID, to: CGWindowID) {
        if let i = habits.firstIndex(where: { $0.from == from && $0.to == to }) { habits[i].count *= 0.5 }
    }

    private mutating func noteGlance(from: CGWindowID, to: CGWindowID, at t: TimeInterval) {
        if let i = habits.firstIndex(where: { $0.from == from && $0.to == to }) {
            habits[i].count = decayed(habits[i], t) + 1
            habits[i].at = t
        } else {
            habits.append(Habit(from: from, to: to, count: 1, at: t))
        }
    }

    /// A glance: the settled pointer leaves the focused window A for B while typing, and comes back
    /// within a few seconds. It counts once typing resumes (see keyDown).
    private mutating func trackGlances(t: TimeInterval, hovered: CGWindowID?) {
        let p = parameters
        if let g = glance, t - g.at > p.glanceMaxSeconds { glance = nil }
        if let r = glanceReturn, t - r.at > p.glanceConfirmSeconds { glanceReturn = nil }
        guard hovered != lastSettledHovered else { return }
        defer { lastSettledHovered = hovered }
        guard let a = current else { return }
        if lastSettledHovered == a, let b = hovered, b != a, t - lastKeyDown <= p.glanceConfirmSeconds {
            glance = Glance(from: a, to: b, at: t)
        } else if let g = glance, hovered == g.from {
            glanceReturn = Glance(from: g.from, to: g.to, at: t)
            glance = nil
        } else if let g = glance, hovered != g.to {
            glance = nil
        }
    }

    // MARK: Geometry

    /// Point ↔ angle conversions through the inverse of the map's local Jacobian (a1, a2; b1, b2).
    struct AngleGeometry {
        let a1: Double, a2: Double, b1: Double, b2: Double, det: Double
        let a0: Double, b0: Double

        init(map: AffineHeadMap) {
            a1 = map.a[1]; a2 = map.a[2]; b1 = map.b[1]; b2 = map.b[2]
            a0 = map.a[0]; b0 = map.b[0]
            let d = a1 * b2 - a2 * b1
            det = abs(d) > 1e-9 ? d : 1e-9
        }

        /// Screen delta (points) → angle delta (degrees).
        func angles(dx: Double, dy: Double) -> (yaw: Double, pitch: Double) {
            ((b2 * dx - a2 * dy) / det, (-b1 * dx + a1 * dy) / det)
        }

        func normalized(dx: Double, dy: Double, sy: Double, sp: Double) -> Double {
            let a = angles(dx: dx, dy: dy)
            return hypot(a.yaw / sy, a.pitch / sp)
        }

        /// In σ units: negative inside the window's visible region (its depth), positive outside.
        func signedDistance(_ p: CGPoint, _ w: TrackedWindow, sigmaYaw sy: Double, sigmaPitch sp: Double) -> Double {
            var best = Double.infinity
            let x = Double(p.x), y = Double(p.y)
            for r in w.visibleRects {
                let minX = Double(r.minX), maxX = Double(r.maxX), minY = Double(r.minY), maxY = Double(r.maxY)
                let z: Double
                if x >= minX, x <= maxX, y >= minY, y <= maxY {
                    let depth = min(normalized(dx: x - minX, dy: 0, sy: sy, sp: sp), normalized(dx: maxX - x, dy: 0, sy: sy, sp: sp),
                                    normalized(dx: 0, dy: y - minY, sy: sy, sp: sp), normalized(dx: 0, dy: maxY - y, sy: sy, sp: sp))
                    z = -depth
                } else {
                    let nx = min(max(x, minX), maxX), ny = min(max(y, minY), maxY)
                    z = normalized(dx: nx - x, dy: ny - y, sy: sy, sp: sp)
                }
                best = min(best, z)
            }
            return best
        }

        /// With yaw unknown only pitch can tell windows apart: the window's pitch span against the pitch.
        func signedPitchDistance(_ pitch: Double, _ w: TrackedWindow, sigmaPitch sp: Double) -> Double {
            var best = Double.infinity
            for r in w.visibleRects {
                let corners = [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY)]
                let pitches = corners.map { (-b1 * (Double($0.0) - a0) + a1 * (Double($0.1) - b0)) / det }
                guard let lo = pitches.min(), let hi = pitches.max() else { continue }
                let z = pitch >= lo && pitch <= hi ? -min(pitch - lo, hi - pitch) / sp : min(abs(pitch - lo), abs(pitch - hi)) / sp
                best = min(best, z)
            }
            return best
        }

        static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> Double {
            let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
            return dx * dx + dy * dy
        }
    }

    /// The point inside the window's visible region nearest `p`, kept clear of the edge.
    static func nearestInside(_ p: CGPoint, _ w: TrackedWindow) -> CGPoint? {
        var best: (CGPoint, Double)?
        for r in w.visibleRects {
            let margin = min(40, 0.1 * min(r.width, r.height))
            let inner = r.insetBy(dx: margin, dy: margin)
            let q = CGPoint(x: min(max(p.x, inner.minX), inner.maxX), y: min(max(p.y, inner.minY), inner.maxY))
            let d = AngleGeometry.distanceSquared(p, q)
            if d < (best?.1 ?? .infinity) { best = (q, d) }
        }
        return best?.0
    }

    static func phi(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
