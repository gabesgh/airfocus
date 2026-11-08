import CoreGraphics
import Foundation

/// Decides which window the head is pointed at and when to switch focus (R§8.5, spec §2.4).
/// Biased towards not switching: a wrong focus sends keystrokes to the wrong agent.
public struct TargetSelector: Sendable {
    public struct Config: Sendable {
        public var dwell: TimeInterval = 0.45            // candidate must win continuously
        public var maxSpeedDegPerSec = 25.0              // settled-head gate (gyro magnitude)
        public var hysteresisMinPoints: CGFloat = 40     // current window's hit area grows by
        public var hysteresisFraction: CGFloat = 0.08    //   max(40 pt, 8% of its size)
        public var cooldown: TimeInterval = 0.6
        public var typingHold: TimeInterval = 0.7
        public var offScreenMargin = 150.0               // points outside every screen
        public var keyboardGlanceDegrees = 10.0          // below the lowest calibrated pitch
        public var gapMaxDegrees = 4.0
        public var autoSwitch = true                     // false = hotkey-only mode

        public init() {}
    }

    public enum Reject: String, Sendable {
        case keyboardGlance, offScreen, noWindow, moving, cooldown, typing, externalFocusHold
    }

    public struct Input {
        public var point: CGPoint
        public var yaw: Double
        public var pitch: Double
        public var speed: Double                 // °/s, raw gyro magnitude
        public var now: TimeInterval
        public var lastKeyDown: TimeInterval
        public var windows: [TrackedWindow]      // front to back
        public var screensCG: [CGRect]
        public var lowestCalibratedPitch: Double?
        /// Gap disambiguation in angle space; nil disables it.
        public var gapResolver: ((Double, Double, [TrackedWindow]) -> CGWindowID?)?

        public init(point: CGPoint, yaw: Double, pitch: Double, speed: Double, now: TimeInterval,
                    lastKeyDown: TimeInterval, windows: [TrackedWindow], screensCG: [CGRect],
                    lowestCalibratedPitch: Double?,
                    gapResolver: ((Double, Double, [TrackedWindow]) -> CGWindowID?)? = nil) {
            self.point = point; self.yaw = yaw; self.pitch = pitch; self.speed = speed; self.now = now
            self.lastKeyDown = lastKeyDown; self.windows = windows; self.screensCG = screensCG
            self.lowestCalibratedPitch = lowestCalibratedPitch; self.gapResolver = gapResolver
        }
    }

    public struct Decision: Equatable, Sendable {
        /// Focus this window now.
        public var switchTo: CGWindowID?
        /// The window under the head pointer (front-to-back hit test, then gap disambiguation),
        /// ignoring dwell and hysteresis. This is what ⌃⌥⌘F focuses.
        public var underPointer: CGWindowID?
        /// The candidate whose dwell is running, and how far along it is (0...1).
        public var pending: CGWindowID?
        public var pendingProgress: Double = 0
        public var reject: Reject?

        public init(switchTo: CGWindowID? = nil, underPointer: CGWindowID? = nil, pending: CGWindowID? = nil,
                    pendingProgress: Double = 0, reject: Reject? = nil) {
            self.switchTo = switchTo; self.underPointer = underPointer; self.pending = pending
            self.pendingProgress = pendingProgress; self.reject = reject
        }
    }

    public var config: Config
    public private(set) var current: CGWindowID?
    private var candidate: CGWindowID?
    private var candidateSince: TimeInterval = 0
    private var lastSwitch: TimeInterval = -.infinity
    // After a click / ⌘-Tab elsewhere, don't yank focus back to whatever the (possibly drifted)
    // pointer was on; wait until the pointer moves to a different window or onto the new focus.
    private var externalHoldArmed = false
    private var externalHoldWindow: CGWindowID?

    public init(config: Config = Config()) { self.config = config }

    public mutating func reset() {
        current = nil; candidate = nil; lastSwitch = -.infinity
        externalHoldArmed = false; externalHoldWindow = nil
    }

    /// The window under the pointer, or nil when a reject applies.
    public func windowUnderPointer(_ input: Input) -> (CGWindowID?, Reject?) {
        if let low = input.lowestCalibratedPitch, input.pitch < low - config.keyboardGlanceDegrees {
            return (nil, .keyboardGlance)
        }
        if Geometry.distance(from: input.point, toAnyOf: input.screensCG) > config.offScreenMargin {
            return (nil, .offScreen)
        }
        if let hit = WindowFilter.window(at: input.point, in: input.windows) { return (hit.id, nil) }
        if let id = input.gapResolver?(input.yaw, input.pitch, input.windows) { return (id, nil) }
        return (nil, .noWindow)
    }

    public mutating func update(_ input: Input) -> Decision {
        let (hovered, reject) = windowUnderPointer(input)
        if let reject { candidate = nil; return Decision(reject: reject) }

        // Hysteresis: stay on the current window while the pointer is inside its grown visible region.
        if let cur = current, let w = input.windows.first(where: { $0.id == cur }) {
            let mx = max(config.hysteresisMinPoints, config.hysteresisFraction * w.frameCG.width)
            let my = max(config.hysteresisMinPoints, config.hysteresisFraction * w.frameCG.height)
            if w.visibleRects.contains(where: { $0.insetBy(dx: -mx, dy: -my).contains(input.point) }) {
                candidate = nil
                externalHoldArmed = false
                return Decision(underPointer: hovered)
            }
        }
        guard let hit = hovered, hit != current else {
            candidate = nil
            if hovered != nil { externalHoldArmed = false }
            return Decision(underPointer: hovered, reject: hovered == nil ? .noWindow : nil)
        }
        if externalHoldArmed {
            if externalHoldWindow == nil { externalHoldWindow = hit }
            if externalHoldWindow == hit {
                candidate = nil
                return Decision(underPointer: hit, reject: .externalFocusHold)
            }
            externalHoldArmed = false
        }
        guard config.autoSwitch else {
            candidate = nil
            return Decision(underPointer: hit)
        }
        if hit != candidate {
            candidate = hit
            candidateSince = input.now
            return Decision(underPointer: hit, pending: hit, pendingProgress: 0)
        }
        let progress = min(1, (input.now - candidateSince) / max(config.dwell, 1e-3))
        var decision = Decision(underPointer: hit, pending: hit, pendingProgress: progress)
        guard progress >= 1 else { return decision }
        if input.speed > config.maxSpeedDegPerSec { decision.reject = .moving; return decision }
        if input.now - lastSwitch < config.cooldown { decision.reject = .cooldown; return decision }
        if input.now - input.lastKeyDown < config.typingHold { decision.reject = .typing; return decision }

        current = hit
        lastSwitch = input.now
        candidate = nil
        return Decision(switchTo: hit, underPointer: hit)
    }

    /// The user focused a window by click or ⌘-Tab: adopt it (spec §2.4).
    public mutating func noteExternalFocus(_ id: CGWindowID?, now: TimeInterval) {
        guard id != current else { return }
        adoptWithHold(id, now: now)
    }

    /// Focus was just chosen somewhere the head isn't aiming, such as a Mission Control thumbnail:
    /// hold it even if it's the window already in focus, until the head moves somewhere else.
    public mutating func adoptWithHold(_ id: CGWindowID?, now: TimeInterval) {
        current = id
        candidate = nil
        lastSwitch = now
        externalHoldArmed = id != nil
        externalHoldWindow = nil
    }

    /// Adopt the actually focused window without any hold (tracking just started, or a recenter).
    public mutating func syncCurrent(_ id: CGWindowID?) {
        current = id
        candidate = nil
        externalHoldArmed = false
    }

    /// The user pressed ⌃⌥⌘F, or we focused a window for another explicit reason.
    public mutating func noteManualFocus(_ id: CGWindowID, now: TimeInterval) {
        current = id
        candidate = nil
        lastSwitch = now
        externalHoldArmed = false
    }
}
