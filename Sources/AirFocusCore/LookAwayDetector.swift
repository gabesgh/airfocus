import Foundation

/// "Clearly looking away" state machine (R§9.4, R§9.5, spec §2.6). Pure: the controller feeds it
/// poses and input-idle times and acts on the returned actions.
public struct LookAwayDetector: Sendable {
    public enum Action: Equatable, Sendable { case startScreenSaver, wakeForUnlock }

    public struct Config: Sendable {
        public var yawMargin = 30.0               // beyond the left/right envelope edge
        public var pitchUpMargin = 25.0           // above the top edge
        public var countLookingDown = false       // looking down never counts by default
        public var pitchDownMargin = 45.0         // only if countLookingDown
        public var awayHold: TimeInterval = 5.0   // the user's delay (5/10/20/30/60 s)
        public var downAwayHold: TimeInterval = 15.0
        public var flickerTolerance: TimeInterval = 0.3
        public var backMargin = 10.0              // envelope grown by this for look-back
        public var backHold: TimeInterval = 0.6
        public var backMaxSpeed = 30.0            // °/s: "settled" for the look-back test
        public var wakeRetryInterval: TimeInterval = 10
        public var removalHold: TimeInterval = 10 // "treat removing AirPods as away"

        public init() {}
    }

    public var config: Config
    public private(set) var isAway = false
    /// After a stream restart the yaw zero is arbitrary: only gravity-referenced pitch is trusted.
    public private(set) var yawUnanchored = false

    private var awaySince: TimeInterval?
    private var lastOutside: TimeInterval = -.infinity
    private var backSince: TimeInterval?
    private var lastWake: TimeInterval = -.infinity
    private var disconnectedSince: TimeInterval?

    public init(config: Config = Config()) { self.config = config }

    /// Forget any in-progress or active episode (tracking stopped, feature disabled).
    public mutating func reset() {
        isAway = false; awaySince = nil; backSince = nil; lastOutside = -.infinity
        disconnectedSince = nil
    }

    public mutating func markYawUnanchored() { yawUnanchored = true; awaySince = nil }
    public mutating func markYawAnchored() { yawUnanchored = false }

    /// Feed every filtered pose while tracking. `speed` is the raw gyro magnitude in °/s and
    /// `inputIdle` the seconds since the last keyboard/mouse/trackpad event.
    public mutating func update(yaw: Double, pitch: Double, speed: Double, now: TimeInterval,
                                envelope env: AngleEnvelope, inputIdle: TimeInterval) -> Action? {
        disconnectedSince = nil
        if !isAway {
            // With an unanchored yaw a sideways test could fire on a stale reference; only pitch counts.
            let sideways = !yawUnanchored && max(env.yawMin - yaw, yaw - env.yawMax) > config.yawMargin
            let upward = pitch - env.pitchMax > config.pitchUpMargin
            let downward = config.countLookingDown && env.pitchMin - pitch > config.pitchDownMargin
            if sideways || upward || downward {
                lastOutside = now
                if awaySince == nil { awaySince = now }
                let hold = (downward && !sideways && !upward) ? config.downAwayHold : config.awayHold
                // Veto: any input within the delay window means someone is at the keyboard.
                if let since = awaySince, now - since >= hold, inputIdle >= hold {
                    isAway = true; awaySince = nil; backSince = nil
                    return .startScreenSaver
                }
            } else if now - lastOutside > config.flickerTolerance {
                awaySince = nil   // brief returns under the tolerance don't reset the timer
            }
            return nil
        }

        let grown = env.grown(by: config.backMargin)
        let inside = yawUnanchored ? grown.containsPitch(pitch) : grown.contains(yaw: yaw, pitch: pitch)
        if inside && speed < config.backMaxSpeed {
            if backSince == nil { backSince = now }
            if let since = backSince, now - since >= config.backHold, now - lastWake >= config.wakeRetryInterval {
                lastWake = now
                return .wakeForUnlock
            }
        } else {
            backSince = nil
        }
        return nil
    }

    /// Feed while the AirPods are disconnected (or no samples arrive). Only acts when the user
    /// opted into "Treat removing AirPods as away"; reconnecting is never a wake trigger by itself.
    public mutating func updateDisconnected(now: TimeInterval, inputIdle: TimeInterval,
                                            treatRemovalAsAway: Bool) -> Action? {
        backSince = nil
        guard !isAway, treatRemovalAsAway else { disconnectedSince = nil; return nil }
        if disconnectedSince == nil { disconnectedSince = now }
        if let since = disconnectedSince, now - since >= config.removalHold, inputIdle >= config.removalHold {
            isAway = true; disconnectedSince = nil; awaySince = nil
            return .startScreenSaver
        }
        return nil
    }

    /// Call on com.apple.screenIsUnlocked, or screensaver didstop with the session unlocked.
    public mutating func userReturned() {
        isAway = false; awaySince = nil; backSince = nil; lastOutside = -.infinity; disconnectedSince = nil
    }
}
