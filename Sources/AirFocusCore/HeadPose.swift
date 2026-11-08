import CoreGraphics
import Foundation

/// One head pose in degrees (CoreMotion convention: yaw > 0 = turned left, pitch > 0 = looking up;
/// UNVERIFIED on the user's hardware, R§1.5). The affine calibration absorbs the signs either way.
public struct HeadSample: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Raw gyro magnitude, °/s. Used for every "is the head moving" gate (lower latency than a
    /// derivative of the filtered angle, R§8.4).
    public var speed: Double
    /// Device clock (CMDeviceMotion.timestamp): only differences are meaningful.
    public var deviceTime: TimeInterval
    /// Host uptime when the sample reached us; comparable with NSEvent timestamps.
    public var hostTime: TimeInterval

    public init(yaw: Double, pitch: Double, roll: Double = 0, speed: Double, deviceTime: TimeInterval,
                hostTime: TimeInterval) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.speed = speed
        self.deviceTime = deviceTime; self.hostTime = hostTime
    }
}

/// Turns raw CMDeviceMotion attitude into a continuous pose (R§1.8):
///  - unwraps yaw across ±180°;
///  - re-bases when the streaming bud changes (yaw and pitch) and when yaw steps by more than the
///    gyro could explain (e.g. Spatial Audio playback re-centring yaw). Both heuristics are
///    UNVERIFIED on hardware; thresholds come from the research.
public struct PoseUnwrapper: Sendable {
    public enum Jump: Equatable, Sendable {
        case sensorSwitch(dYaw: Double, dPitch: Double)
        case unexplainedYawStep(dYaw: Double)
    }

    public struct Output: Equatable, Sendable {
        public var yaw: Double
        public var pitch: Double
        public var roll: Double
        public var speed: Double
        public var jump: Jump?
    }

    /// A yaw step counts as a jump when it exceeds this many degrees...
    public var minJumpDegrees = 10.0
    /// ...and exceeds `gyroFactor` × what the gyro integrated over the interval, plus `slackDegrees`.
    public var gyroFactor = 3.0
    public var slackDegrees = 5.0

    private var lastRawYaw: Double?
    private var turns = 0.0
    private var yawOffset = 0.0
    private var pitchOffset = 0.0
    private var lastOut: (yaw: Double, pitch: Double)?
    private var lastTimestamp: TimeInterval?
    private var lastSensor: Int?

    public init() {}

    /// Forget continuity: a restarted stream has a new arbitrary yaw zero anyway.
    public mutating func reset() {
        lastRawYaw = nil; turns = 0; yawOffset = 0; pitchOffset = 0
        lastOut = nil; lastTimestamp = nil; lastSensor = nil
    }

    /// Angles in radians, rotation rate in rad/s, `sensor` = CMDeviceMotion.SensorLocation raw value.
    public mutating func process(yawRad: Double, pitchRad: Double, rollRad: Double,
                                 rotationRate r: (x: Double, y: Double, z: Double),
                                 timestamp: TimeInterval, sensor: Int) -> Output {
        if let last = lastRawYaw {
            let step = yawRad - last
            if step > .pi { turns -= 1 } else if step < -.pi { turns += 1 }
        }
        lastRawYaw = yawRad
        let deg = 180 / Double.pi
        var yaw = (yawRad + turns * 2 * .pi) * deg + yawOffset
        var pitch = pitchRad * deg + pitchOffset
        let speed = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * deg
        var jump: Jump?

        if let prev = lastOut, let pt = lastTimestamp {
            let dt = max(timestamp - pt, 1e-3)
            let dYaw = yaw - prev.yaw
            if let s = lastSensor, s != sensor {
                let dPitch = pitch - prev.pitch
                yawOffset -= dYaw; pitchOffset -= dPitch
                yaw = prev.yaw; pitch = prev.pitch
                jump = .sensorSwitch(dYaw: dYaw, dPitch: dPitch)
            } else if abs(dYaw) > minJumpDegrees, abs(dYaw) > gyroFactor * speed * dt + slackDegrees {
                yawOffset -= dYaw
                yaw = prev.yaw
                jump = .unexplainedYawStep(dYaw: dYaw)
            }
        }
        lastSensor = sensor
        lastOut = (yaw, pitch)
        lastTimestamp = timestamp
        return Output(yaw: yaw, pitch: pitch, roll: rollRad * deg, speed: speed, jump: jump)
    }
}

/// Mouse simulation of the head (spec §3.3): ~40 pt per degree around the main screen's centre;
/// rotation speed from the mouse velocity. Points are in CG space (y down).
public struct MouseHeadModel: Sendable {
    public var pointsPerDegree = 40.0
    public var centre: CGPoint
    private var last: (p: CGPoint, t: TimeInterval)?

    public init(centre: CGPoint, pointsPerDegree: Double = 40) {
        self.centre = centre
        self.pointsPerDegree = pointsPerDegree
    }

    /// Mouse right → head turned right → yaw decreases; mouse up → pitch increases (CoreMotion signs).
    public func angles(for p: CGPoint) -> (yaw: Double, pitch: Double) {
        (-Double(p.x - centre.x) / pointsPerDegree, Double(centre.y - p.y) / pointsPerDegree)
    }

    public mutating func sample(mouse p: CGPoint, at t: TimeInterval) -> HeadSample {
        var speed = 0.0
        if let last, t > last.t {
            speed = Geometry.distance(p, last.p) / (t - last.t) / pointsPerDegree
        }
        last = (p, t)
        let a = angles(for: p)
        return HeadSample(yaw: a.yaw, pitch: a.pitch, speed: speed, deviceTime: t, hostTime: t)
    }
}

/// Implicit recentring from interaction (R§8.6 item 2). Deliberately conservative:
/// only when typing into the focused window W with the head settled for 1.5 s, the pointer is
/// outside W but within one window-width of it, and NOT on another window (the user may simply be
/// reading a neighbour while typing). Small steps, rate-limited, with a total budget per anchor.
public struct ImplicitRecenterPolicy: Sendable {
    /// Flip to false to ship without the heuristic (spec §2.4: "behind a constant").
    public static let isEnabled = true

    public var minSettled: TimeInterval = 1.5
    public var fraction = 0.15
    public var maxDegreesPerEvent = 0.5
    public var maxTotalDegrees = 3.0
    public var minInterval: TimeInterval = 2.0

    public private(set) var totalApplied = 0.0
    private var lastApplied: TimeInterval = -.infinity

    public init() {}

    /// Call after an explicit recenter or a fresh calibration.
    public mutating func resetBudget() { totalApplied = 0; lastApplied = -.infinity }

    public func shouldNudge(point: CGPoint, focused: TrackedWindow, windows: [TrackedWindow],
                            settledFor: TimeInterval, now: TimeInterval) -> Bool {
        guard Self.isEnabled, settledFor >= minSettled, now - lastApplied >= minInterval,
              totalApplied < maxTotalDegrees else { return false }
        guard !focused.visibleContains(point) else { return false }
        guard Geometry.distance(from: point, to: focused.frameCG) <= Double(focused.frameCG.width) else { return false }
        return !windows.contains { $0.id != focused.id && $0.visibleContains(point) }
    }

    public mutating func noteApplied(degrees: Double, now: TimeInterval) {
        totalApplied += degrees
        lastApplied = now
    }
}
