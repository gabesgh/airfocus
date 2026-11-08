import Foundation

/// A deliberate head flick (spec §2.9): sudden, short, mostly along one axis, and bigger than a
/// glance but smaller than a full turn. Pure: the controller feeds it raw poses at the sensor rate
/// and acts on the bursts it returns.
///
/// Speed is what separates a flick from looking at another window. Where the head started rules out
/// the other fast movements: coming back up from the keyboard, or back from looking away, starts
/// off the screen. The thresholds are first guesses to tune against the log, which records bursts.
public struct FlickDetector: Sendable {
    public enum Direction: String, Sendable { case up, left, right }

    public enum Rejection: String, CaseIterable, Sendable {
        case down = "downward"
        case slow = "too slow"
        case notSudden = "not sudden"
        case long = "too long"
        case small = "too small"
        case large = "too large"
        case diagonal
        case noGyro = "gyro disagrees"
        case cooldown
        case returnStroke = "return stroke"
        case unanchored = "yaw unanchored"
        case offScreen = "started off screen"
        case belowTop = "stopped below the top of the screen"
        case typing
        case turnedOff = "turned off"
    }

    public struct Config: Sendable {
        public var upEnabled = true
        public var sidewaysEnabled = true
        public var onsetRate = 90.0                   // °/s: a burst starts...
        public var endRate = 35.0                     // ...and ends
        public var yawPeakRate = 190.0                // °/s: a brisk glance peaks well under this
        public var pitchPeakRate = 130.0              // necks extend more slowly than they turn
        public var maxRise: TimeInterval = 0.16       // onset to peak: "sudden"
        public var maxDuration: TimeInterval = 0.4
        public var yawAmplitude = 10.0...45.0         // degrees: past this it's a turn, not a flick
        public var pitchAmplitude = 8.0...40.0
        public var minDominance = 2.0                 // main axis over the other: no diagonals
        public var minGyroAgreement = 0.6             // of the peak rate: rules out attitude steps
        public var maxSampleGap: TimeInterval = 0.12
        public var refractory: TimeInterval = 1.2     // Desktops take ~1.05 s, and the Dock drops keys until then
        public var returnWindow: TimeInterval = 1.8   // the head coming back from a flick isn't a flick
        public var yawStartMargin = 8.0               // degrees outside the screen a side flick can start
        public var pitchStartMargin = 3.0             // ...or an up flick, so not from the keyboard
        public var typingHold: TimeInterval = 0.25

        public init() {}

        /// Firm (0) asks for 35% more, Light (1) for 30% less. The midpoint is the defaults exactly.
        public init(sensitivity: Double) {
            let s = min(1, max(0, sensitivity))
            let scale = s < 0.5 ? 1.35 - 0.35 * (s / 0.5) : 1 - 0.3 * ((s - 0.5) / 0.5)
            yawPeakRate *= scale
            pitchPeakRate *= scale
            yawAmplitude = (yawAmplitude.lowerBound * scale)...yawAmplitude.upperBound
            pitchAmplitude = (pitchAmplitude.lowerBound * scale)...pitchAmplitude.upperBound
        }
    }

    /// One finished burst of fast head movement, fired or not.
    public struct Burst: Equatable, Sendable {
        public var direction: Direction?          // nil for a downward movement
        public var peakRate: Double               // °/s along the main axis
        public var amplitude: Double              // degrees along the main axis
        public var crossAmplitude: Double         // degrees along the other axis
        public var rise: TimeInterval
        public var duration: TimeInterval
        public var rejection: Rejection?

        public var fired: Bool { rejection == nil }

        public var summary: String {
            String(format: "%@: peak %.0f°/s, %.1f° (cross %.1f°), rise %.0f ms, %.0f ms: %@",
                   direction?.rawValue ?? "down", peakRate, amplitude, crossAmplitude, rise * 1000, duration * 1000,
                   rejection.map { "rejected, \($0.rawValue)" } ?? "fired")
        }
    }

    private struct Pose: Sendable { var yaw: Double; var pitch: Double; var time: TimeInterval }

    private struct Active: Sendable {
        var start: Pose
        var farthest: Pose
        var farthestDistance = 0.0
        var onset: TimeInterval
        var peakRate = 0.0
        var peakAt: TimeInterval
        var peakYawRate = 0.0
        var peakPitchRate = 0.0
        var peakGyro = 0.0
    }

    public var config: Config
    private var recent: [Pose] = []
    private var active: Active?
    private var awaitingQuiet = false
    private var lastFired: (direction: Direction, time: TimeInterval)?

    public init(config: Config = Config()) { self.config = config }

    /// Feed every raw pose. `time` is the device clock, `speed` the raw gyro magnitude in °/s.
    /// Returns a burst the moment one finishes: when the head slows, or turns around.
    public mutating func update(yaw: Double, pitch: Double, speed: Double, time: TimeInterval,
                                envelope: AngleEnvelope?, yawAnchored: Bool,
                                secondsSinceKey: TimeInterval) -> Burst? {
        let pose = Pose(yaw: yaw, pitch: pitch, time: time)
        guard let last = recent.last, time > last.time, time - last.time <= config.maxSampleGap else {
            // A rate across a gap means nothing, and neither does a burst that straddles one.
            recent = [pose]
            active = nil
            awaitingQuiet = false
            return nil
        }
        let from = recent[0]
        recent.append(pose)
        if recent.count > 2 { recent.removeFirst() }      // so rates span two samples, 40 ms
        let dt = time - from.time
        let yawRate = (yaw - from.yaw) / dt, pitchRate = (pitch - from.pitch) / dt
        let rate = hypot(yawRate, pitchRate)

        guard var b = active else {
            if awaitingQuiet {
                if rate < config.endRate { awaitingQuiet = false }
            } else if rate >= config.onsetRate {
                active = Active(start: from, farthest: pose, onset: time, peakRate: rate, peakAt: time,
                                peakYawRate: abs(yawRate), peakPitchRate: abs(pitchRate), peakGyro: speed)
            }
            return nil
        }
        if rate > b.peakRate { b.peakRate = rate; b.peakAt = time }
        b.peakYawRate = max(b.peakYawRate, abs(yawRate))
        b.peakPitchRate = max(b.peakPitchRate, abs(pitchRate))
        b.peakGyro = max(b.peakGyro, speed)
        let dYaw = yaw - b.start.yaw, dPitch = pitch - b.start.pitch
        let distance = hypot(dYaw, dPitch)
        if distance > b.farthestDistance { b.farthestDistance = distance; b.farthest = pose }

        let tooLong = time - b.onset > config.maxDuration
        let turningBack = yawRate * dYaw + pitchRate * dPitch < 0
        guard rate < config.endRate || turningBack || tooLong else {
            active = b
            return nil
        }
        active = nil
        if tooLong { awaitingQuiet = true }     // the rest of a long movement isn't a new burst
        return classify(b, end: time, envelope: envelope, yawAnchored: yawAnchored, secondsSinceKey: secondsSinceKey)
    }

    private mutating func classify(_ b: Active, end: TimeInterval, envelope env: AngleEnvelope?, yawAnchored: Bool,
                                   secondsSinceKey: TimeInterval) -> Burst {
        let dYaw = b.farthest.yaw - b.start.yaw, dPitch = b.farthest.pitch - b.start.pitch
        let sideways = abs(dYaw) >= abs(dPitch)
        let direction: Direction? = sideways ? (dYaw > 0 ? .left : .right) : (dPitch > 0 ? .up : nil)
        var burst = Burst(direction: direction, peakRate: sideways ? b.peakYawRate : b.peakPitchRate,
                          amplitude: sideways ? abs(dYaw) : abs(dPitch), crossAmplitude: sideways ? abs(dPitch) : abs(dYaw),
                          rise: b.peakAt - b.onset, duration: end - b.onset, rejection: nil)
        burst.rejection = rejection(for: burst, start: b.start, farthest: b.farthest, peakGyro: b.peakGyro, end: end,
                                    envelope: env, yawAnchored: yawAnchored, secondsSinceKey: secondsSinceKey)
        if burst.fired, let direction { lastFired = (direction, end) }
        return burst
    }

    private func rejection(for b: Burst, start: Pose, farthest: Pose, peakGyro: Double, end: TimeInterval,
                           envelope env: AngleEnvelope?, yawAnchored: Bool, secondsSinceKey: TimeInterval) -> Rejection? {
        guard let direction = b.direction else { return .down }
        let sideways = direction != .up
        // First, so a direction that's off can't start the cooldown and block the other one.
        if !(sideways ? config.sidewaysEnabled : config.upEnabled) { return .turnedOff }
        let peakNeeded = sideways ? config.yawPeakRate : config.pitchPeakRate
        let range = sideways ? config.yawAmplitude : config.pitchAmplitude
        if b.peakRate < peakNeeded { return .slow }
        if b.rise > config.maxRise { return .notSudden }
        if b.duration > config.maxDuration { return .long }
        if b.amplitude < range.lowerBound { return .small }
        if b.amplitude > range.upperBound { return .large }
        if b.crossAmplitude * config.minDominance > b.amplitude { return .diagonal }
        if peakGyro < config.minGyroAgreement * peakNeeded { return .noGyro }
        if let last = lastFired {
            let since = end - last.time
            if since < config.refractory { return .cooldown }
            let opposite = (direction == .left && last.direction == .right) || (direction == .right && last.direction == .left)
            if opposite && since < config.returnWindow { return .returnStroke }
        }
        guard let env else { return .offScreen }
        if sideways {
            // A stream restart leaves the yaw zero arbitrary, so where the head "started" means nothing.
            guard yawAnchored else { return .unanchored }
            if start.yaw < env.yawMin - config.yawStartMargin || start.yaw > env.yawMax + config.yawStartMargin {
                return .offScreen
            }
        } else {
            if start.pitch < env.pitchMin - config.pitchStartMargin { return .offScreen }
            if farthest.pitch < env.pitchMax { return .belowTop }
        }
        if secondsSinceKey < config.typingHold { return .typing }
        return nil
    }
}
