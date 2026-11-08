import CoreGraphics
import Foundation

/// One calibration observation: averaged head angles (degrees) while pointing at `screen` (CG space).
public struct CalibrationSample: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var screen: CGPoint

    public init(yaw: Double, pitch: Double, screen: CGPoint) {
        self.yaw = yaw; self.pitch = pitch; self.screen = screen
    }
}

/// Least-squares affine map from head angles to a global CG point (R§8.2):
///   x = a0 + a1*yaw + a2*pitch,  y = b0 + b1*yaw + b2*pitch
public struct AffineHeadMap: Codable, Equatable, Sendable {
    public var a: [Double]
    public var b: [Double]

    public init(a: [Double], b: [Double]) {
        precondition(a.count == 3 && b.count == 3)
        self.a = a; self.b = b
    }

    /// Ridge-regularised fit on centred data. `ridge` is in degrees² per sample: it only bites in a
    /// direction whose angular spread is comparable to it (near-collinear points), where it pulls the
    /// slope towards zero instead of letting noise blow it up. The intercept is not penalised.
    public static func fit(_ s: [CalibrationSample], ridge: Double = 0.01) -> AffineHeadMap? {
        guard s.count >= 3 else { return nil }
        let n = Double(s.count)
        let my = s.reduce(0) { $0 + $1.yaw } / n
        let mp = s.reduce(0) { $0 + $1.pitch } / n
        let mx = s.reduce(0) { $0 + Double($1.screen.x) } / n
        let msy = s.reduce(0) { $0 + Double($1.screen.y) } / n

        var syy = 0.0, syp = 0.0, spp = 0.0, syx = 0.0, spx = 0.0, sysy = 0.0, spsy = 0.0
        for p in s {
            let dy = p.yaw - my, dp = p.pitch - mp
            let dx = Double(p.screen.x) - mx, dsy = Double(p.screen.y) - msy
            syy += dy * dy; syp += dy * dp; spp += dp * dp
            syx += dy * dx; spx += dp * dx
            sysy += dy * dsy; spsy += dp * dsy
        }
        let lambda = max(ridge, 0) * n
        let c11 = syy + lambda, c12 = syp, c22 = spp + lambda
        let det = c11 * c22 - c12 * c12
        guard abs(det) > 1e-12 else { return nil }
        func solve(_ r1: Double, _ r2: Double) -> (Double, Double) {
            ((c22 * r1 - c12 * r2) / det, (c11 * r2 - c12 * r1) / det)
        }
        let (a1, a2) = solve(syx, spx)
        let (b1, b2) = solve(sysy, spsy)
        return AffineHeadMap(a: [mx - a1 * my - a2 * mp, a1, a2],
                             b: [msy - b1 * my - b2 * mp, b1, b2])
    }

    public func point(yaw: Double, pitch: Double) -> CGPoint {
        CGPoint(x: a[0] + a[1] * yaw + a[2] * pitch, y: b[0] + b[1] * yaw + b[2] * pitch)
    }

    /// Determinant of the linear part; near zero means the map cannot be inverted.
    public var determinant: Double { a[1] * b[2] - a[2] * b[1] }

    /// Inverse map (R§9.5): screen point -> (yaw, pitch). Nil when the linear part is singular.
    public func angles(for p: CGPoint) -> (yaw: Double, pitch: Double)? {
        let det = determinant
        guard abs(det) > 1e-9 else { return nil }
        let x = Double(p.x) - a[0], y = Double(p.y) - b[0]
        return ((b[2] * x - a[2] * y) / det, (-b[1] * x + a[1] * y) / det)
    }

    /// Angle delta whose image under the linear part is the screen delta `d`.
    public func angleDelta(forScreenDelta d: CGVector) -> (yaw: Double, pitch: Double)? {
        let det = determinant
        guard abs(det) > 1e-9 else { return nil }
        let x = Double(d.dx), y = Double(d.dy)
        return ((b[2] * x - a[2] * y) / det, (-b[1] * x + a[1] * y) / det)
    }

    /// One-point recalibration (drift, reconnect): shift so the current pose maps onto `target`.
    public mutating func recenter(yaw: Double, pitch: Double, onto target: CGPoint) {
        let p = point(yaw: yaw, pitch: pitch)
        a[0] += Double(target.x - p.x)
        b[0] += Double(target.y - p.y)
    }

    /// Bounding box, in head angles, of every screen's corners (R§9.5).
    public func envelope(screensCG: [CGRect]) -> AngleEnvelope? {
        let corners = screensCG.flatMap {
            [CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.minY),
             CGPoint(x: $0.minX, y: $0.maxY), CGPoint(x: $0.maxX, y: $0.maxY)]
        }
        let angs = corners.compactMap { angles(for: $0) }
        guard let first = angs.first else { return nil }
        var env = AngleEnvelope(yawMin: first.yaw, yawMax: first.yaw, pitchMin: first.pitch, pitchMax: first.pitch)
        for g in angs.dropFirst() {
            env.yawMin = min(env.yawMin, g.yaw); env.yawMax = max(env.yawMax, g.yaw)
            env.pitchMin = min(env.pitchMin, g.pitch); env.pitchMax = max(env.pitchMax, g.pitch)
        }
        return env
    }

    /// Fit quality: RMS distance in points, and mean angular distance in degrees between each
    /// measured pose and the pose the map says should land on that sample's target.
    public func residuals(_ s: [CalibrationSample]) -> (rmsPoints: Double, meanDegrees: Double) {
        guard !s.isEmpty else { return (0, 0) }
        var sq = 0.0, deg = 0.0
        for p in s {
            let q = point(yaw: p.yaw, pitch: p.pitch)
            sq += Double((q.x - p.screen.x) * (q.x - p.screen.x) + (q.y - p.screen.y) * (q.y - p.screen.y))
            if let t = angles(for: p.screen) {
                deg += hypot(t.yaw - p.yaw, t.pitch - p.pitch)
            } else {
                deg += .infinity
            }
        }
        return ((sq / Double(s.count)).squareRoot(), deg / Double(s.count))
    }
}

/// The measured pose for a window dot during calibration. Used to disambiguate gaps (spec §2.3).
public struct WindowAnchor: Codable, Equatable, Sendable {
    public var windowID: UInt32
    public var dotCG: CGPoint
    public var yaw: Double
    public var pitch: Double

    public init(windowID: UInt32, dotCG: CGPoint, yaw: Double, pitch: Double) {
        self.windowID = windowID; self.dotCG = dotCG; self.yaw = yaw; self.pitch = pitch
    }
}

/// Everything a calibration produces, persisted per display configuration.
/// Samples and anchors are kept in the *current* head frame: every recenter/nudge shifts them
/// by the same angle offset it applies to the map, so they stay consistent with it.
public struct HeadCalibration: Codable, Equatable, Sendable {
    public var map: AffineHeadMap
    public var samples: [CalibrationSample]
    public var anchors: [WindowAnchor]
    public var displayKey: String
    public var createdAt: Date
    public var rmsErrorPoints: Double
    public var meanErrorDegrees: Double

    public init(map: AffineHeadMap, samples: [CalibrationSample], anchors: [WindowAnchor],
                displayKey: String, createdAt: Date = Date()) {
        self.map = map
        self.samples = samples
        self.anchors = anchors
        self.displayKey = displayKey
        self.createdAt = createdAt
        let r = map.residuals(samples)
        self.rmsErrorPoints = r.rmsPoints
        self.meanErrorDegrees = r.meanDegrees
    }

    /// Fit a calibration; nil with fewer than 3 samples or a degenerate (non-invertible) result.
    public static func fit(samples: [CalibrationSample], anchors: [WindowAnchor], displayKey: String,
                           ridge: Double = 0.01) -> HeadCalibration? {
        guard let map = AffineHeadMap.fit(samples, ridge: ridge), abs(map.determinant) > 1e-6 else { return nil }
        return HeadCalibration(map: map, samples: samples, anchors: anchors, displayKey: displayKey)
    }

    public var lowestCalibratedPitch: Double? { samples.map(\.pitch).min() }

    public func envelope(screensCG: [CGRect]) -> AngleEnvelope? { map.envelope(screensCG: screensCG) }

    /// Explicit recenter (⌃⌥⌘R): the current pose maps exactly onto `target`.
    public mutating func recenter(yaw: Double, pitch: Double, onto target: CGPoint) {
        let p = map.point(yaw: yaw, pitch: pitch)
        shift(byScreenDelta: CGVector(dx: target.x - p.x, dy: target.y - p.y))
    }

    /// Re-anchor yaw only: after a stream restart the yaw zero is arbitrary while pitch stays
    /// gravity-referenced, so shift yaw alone until the current pose maps as close as possible to
    /// `target`. Returns the applied yaw shift in degrees.
    @discardableResult
    public mutating func reanchorYaw(yaw: Double, pitch: Double, onto target: CGPoint) -> Double {
        let p = map.point(yaw: yaw, pitch: pitch)
        let vx = map.a[1], vy = map.b[1]          // screen motion per degree of yaw
        let norm = vx * vx + vy * vy
        guard norm > 1e-12 else { return 0 }
        let delta = (vx * Double(target.x - p.x) + vy * Double(target.y - p.y)) / norm
        shift(byScreenDelta: CGVector(dx: vx * delta, dy: vy * delta))
        return delta
    }

    /// Implicit recentring (R§8.6 item 2): move a fraction of the way towards mapping the current
    /// pose onto `target`, capped in degrees. Returns the applied angular correction in degrees.
    @discardableResult
    public mutating func nudge(yaw: Double, pitch: Double, towards target: CGPoint,
                               fraction: Double, maxDegrees: Double) -> Double {
        let p = map.point(yaw: yaw, pitch: pitch)
        let full = CGVector(dx: target.x - p.x, dy: target.y - p.y)
        guard let d = map.angleDelta(forScreenDelta: full) else { return 0 }
        var dy = d.yaw * fraction, dp = d.pitch * fraction
        let mag = hypot(dy, dp)
        if mag > maxDegrees, mag > 0 { dy *= maxDegrees / mag; dp *= maxDegrees / mag }
        let screen = CGVector(dx: map.a[1] * dy + map.a[2] * dp, dy: map.b[1] * dy + map.b[2] * dp)
        shift(byScreenDelta: screen)
        return hypot(dy, dp)
    }

    private mutating func shift(byScreenDelta d: CGVector) {
        // M'(v) = M(v + δ) with L·δ = d, so stored poses u become u - δ.
        if let delta = map.angleDelta(forScreenDelta: d) {
            for i in samples.indices { samples[i].yaw -= delta.yaw; samples[i].pitch -= delta.pitch }
            for i in anchors.indices { anchors[i].yaw -= delta.yaw; anchors[i].pitch -= delta.pitch }
        }
        map.a[0] += Double(d.dx)
        map.b[0] += Double(d.dy)
    }

    /// Gap disambiguation (R§8.5): the window whose dot is nearest the current pose in angle space,
    /// if within `maxDegrees`. A window keeps its measured anchor while its dot has not moved
    /// (more than `anchorTolerance` points); otherwise its dot goes through the inverse map.
    public func nearestWindowByAngle(yaw: Double, pitch: Double, windows: [TrackedWindow],
                                     maxDegrees: Double = 4, anchorTolerance: Double = 40) -> CGWindowID? {
        var best: (id: CGWindowID, d: Double)?
        for w in windows {
            let ang: (yaw: Double, pitch: Double)?
            if let anchor = anchors.first(where: { $0.windowID == w.id }),
               Geometry.distance(anchor.dotCG, w.targetPointCG) <= anchorTolerance {
                ang = (anchor.yaw, anchor.pitch)
            } else {
                ang = map.angles(for: w.targetPointCG)
            }
            guard let a = ang else { continue }
            let d = hypot(a.yaw - yaw, a.pitch - pitch)
            if d <= maxDegrees, d < (best?.d ?? .infinity) { best = (w.id, d) }
        }
        return best?.id
    }

    public var summary: String {
        String(format: "calibrated (%d points, error %.1f°)", samples.count, meanErrorDegrees)
    }

    /// Settings status row: under 2° is good, above 3° is worth recalibrating (R§8.3).
    public var qualityLabel: String {
        meanErrorDegrees < 2 ? "good" : (meanErrorDegrees <= 3 ? "fair" : "poor, recalibrate")
    }
}

/// UserDefaults persistence keyed by display configuration (spec §2.3).
public final class CalibrationStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = SettingsKey.calibrations) {
        self.defaults = defaults
        self.key = key
    }

    private var all: [String: Data] {
        get { (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    public func load(displayKey: String) -> HeadCalibration? {
        guard let data = all[displayKey] else { return nil }
        return try? JSONDecoder().decode(HeadCalibration.self, from: data)
    }

    public func save(_ calibration: HeadCalibration) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        var dict = all
        dict[calibration.displayKey] = data
        all = dict
    }

    public func clear(displayKey: String) {
        var dict = all
        dict.removeValue(forKey: displayKey)
        all = dict
    }

    public var storedKeys: [String] { all.keys.sorted() }
}
