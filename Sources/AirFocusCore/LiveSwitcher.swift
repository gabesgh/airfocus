import CoreGraphics
import Foundation

/// What the live path is configured with (spec §2.4, §2.9): everything `applySelectorSettings`
/// reads, so a session trace can record it and a replay can rebuild exactly the same switcher.
public struct LiveConfig: Equatable, Sendable {
    public var sensitivity = SettingsDefault.sensitivity
    public var automatic = true                  // focus mode Automatic, not Hotkey only
    public var switchingPaused = false           // yaw needs a recenter
    public var settingsHold = false              // the Settings window or its colour panel is key
    public var flickUp = SettingsDefault.flickUpEnabled
    public var flickSideways = SettingsDefault.flickSidewaysEnabled
    public var flickSensitivity = SettingsDefault.flickSensitivity
    public var simulated = false                 // mouse simulation never fires flicks

    public init() {}
}

/// The live switching decision path, filter → map → selector, with the guards and holds around it:
/// flick holds, Mission Control, adopting focus changes made elsewhere. Pure and deterministic, so
/// the app and `--replay-trace` run the same code and can't drift apart. The app keeps the side
/// effects: focusing, gestures, the overlay and the log.
public struct LiveSwitcher: Sendable {
    /// No switching just after a flick: the head is still coming back, and Desktops take ~1 s to arrive.
    public static let flickHold: TimeInterval = 1.6
    /// The same after Mission Control closes, while the chosen window comes forward.
    public static let missionControlHold: TimeInterval = 0.6
    /// A front window that differs from ours this long after our last request was changed by the user.
    public static let adoptAfterRequest: TimeInterval = 1.0

    /// Which window is in front at a window poll.
    public enum Front: Equatable, Sendable {
        case unknown                 // the frontmost app has no tracked window
        case own                     // AirFocus itself (Settings)
        case window(CGWindowID)
    }

    /// Where a sample stopped.
    public enum Stage: String, Equatable, Sendable {
        case gated                   // look-away episode, screen saver or lock
        case missionControl
        case flickHold
        case selector
    }

    public struct Pose: Equatable, Sendable {
        public var yaw: Double
        public var pitch: Double
        public var point: CGPoint
    }

    public struct Step: Equatable, Sendable {
        public var stage: Stage
        /// A finished flick burst, fired or not; the app performs it and logs it.
        public var burst: FlickDetector.Burst?
        /// The selector's verdict; empty unless `stage` is `.selector`.
        public var decision = TargetSelector.Decision()
    }

    public struct FrontStep: Equatable, Sendable {
        /// The overlay's current highlight should follow `selector.current`.
        public var showCurrent = false
        /// A focus change made elsewhere was adopted, and it's news (for the log).
        public var externalFocus: CGWindowID?
    }

    public private(set) var config = LiveConfig()
    public private(set) var selector = TargetSelector()
    private var filter = HeadPoseFilter()
    private var flicks = FlickDetector()
    public private(set) var flickHoldUntil: TimeInterval = 0
    public private(set) var missionControlOpen = false
    public private(set) var lastFrontWindow: CGWindowID?
    public private(set) var lastFocusRequestAt: TimeInterval = -.infinity
    /// Mission Control closed: hold whatever comes forward, since the head is still where the thumbnail was.
    private var adoptWithHold = false
    public private(set) var lastDecision = TargetSelector.Decision()

    public init() {}

    /// The settings changed, or the pause or the Settings hold did.
    public mutating func configure(_ c: LiveConfig) {
        config = c
        let tuning = SensitivityTuning(sensitivity: c.sensitivity)
        tuning.apply(to: &selector.config)
        filter.setTuning(minCutoff: tuning.filterMinCutoff, beta: tuning.filterBeta, dCutoff: tuning.filterDCutoff)
        selector.config.autoSwitch = c.automatic && !c.switchingPaused && !c.settingsHold
        var flickConfig = FlickDetector.Config(sensitivity: c.flickSensitivity)
        flickConfig.upEnabled = c.flickUp
        flickConfig.sidewaysEnabled = c.flickSideways
        flicks.config = flickConfig
    }

    private var flicksEnabled: Bool { !config.simulated && (config.flickUp || config.flickSideways) }

    // MARK: Lifecycle

    /// Tracking started: smoothing, dwell and focus all start from scratch.
    public mutating func startTracking() {
        filter.reset()
        selector.reset()
        lastFrontWindow = nil
    }

    /// Calibration started: its samples bypass the filter.
    public mutating func resetFilter() { filter.reset() }

    /// A new calibration replaced the map while tracking.
    public mutating func calibrated() {
        selector.reset()
        lastFrontWindow = nil
    }

    // MARK: Samples

    /// Smooth and map one raw sample. Every sample while tracking with a calibration.
    public mutating func track(_ s: HeadSample, map: AffineHeadMap) -> Pose {
        let f = filter.filter(yaw: s.yaw, pitch: s.pitch, at: s.deviceTime)
        return Pose(yaw: f.yaw, pitch: f.pitch, point: map.point(yaw: f.yaw, pitch: f.pitch))
    }

    /// The decision for one tracked sample. `gated`: a look-away episode, screen saver or lock,
    /// which pause everything, flicks included. `lastKeyDown` is the typing guard's input.
    public mutating func decide(_ s: HeadSample, pose: Pose, calibration cal: HeadCalibration, envelope: AngleEnvelope?,
                                yawAnchored: Bool, lastKeyDown: TimeInterval, windows: [TrackedWindow],
                                screensCG: [CGRect], gated: Bool) -> Step {
        guard !gated else { return Step(stage: .gated) }
        let now = s.hostTime
        var burst: FlickDetector.Burst?
        if flicksEnabled,
           let b = flicks.update(yaw: s.yaw, pitch: s.pitch, speed: s.speed, time: s.deviceTime, envelope: envelope,
                                 yawAnchored: yawAnchored, secondsSinceKey: now - lastKeyDown) {
            burst = b
            if b.fired, b.direction != nil {
                flickHoldUntil = now + Self.flickHold
                selector.syncCurrent(selector.current)     // drop a half-finished dwell
            }
        }
        if missionControlOpen { return Step(stage: .missionControl, burst: burst) }
        if now < flickHoldUntil { return Step(stage: .flickHold, burst: burst) }

        let input = TargetSelector.Input(
            point: pose.point, yaw: pose.yaw, pitch: pose.pitch, speed: s.speed, now: now, lastKeyDown: lastKeyDown,
            windows: windows, screensCG: screensCG, lowestCalibratedPitch: cal.lowestCalibratedPitch,
            gapResolver: { yaw, pitch, ws in cal.nearestWindowByAngle(yaw: yaw, pitch: pitch, windows: ws) })
        let d = selector.update(input)
        lastDecision = d
        return Step(stage: .selector, burst: burst, decision: d)
    }

    // MARK: Window polls

    /// Mission Control opened or closed, however it was opened. Returns whether it changed.
    public mutating func updateMissionControl(_ open: Bool, now: TimeInterval) -> Bool {
        guard open != missionControlOpen else { return false }
        missionControlOpen = open
        if !open {
            selector.syncCurrent(nil)                  // adopt whatever the user picked there...
            adoptWithHold = true                       // ...and keep it: the head is still where the thumbnail was
            lastFrontWindow = nil
            flickHoldUntil = now + Self.missionControlHold
        }
        return true
    }

    /// The window in front, at a window poll while tracking (not calibrating, Mission Control closed).
    public mutating func adoptFront(_ front: Front, windows: [TrackedWindow], now: TimeInterval) -> FrontStep {
        var step = FrontStep()
        switch front {
        case .own:
            // Settings is frontmost. If tracking started under it, the topmost window stands in for
            // focus until the user goes back; otherwise leave the selector's choice alone.
            if selector.current == nil, let top = windows.first?.id {
                selector.syncCurrent(top)
                step.showCurrent = true
            }
        case .unknown:
            break
        case .window(let id):
            if selector.current == nil {
                if adoptWithHold {
                    adoptWithHold = false
                    selector.adoptWithHold(id, now: now)
                } else {
                    selector.syncCurrent(id)             // tracking just started: adopt what is focused
                }
            } else if id != selector.current && now - lastFocusRequestAt > Self.adoptAfterRequest {
                // Click / ⌘-Tab elsewhere, or our request didn't take: adopt reality, don't fight it.
                if id != lastFrontWindow { step.externalFocus = id }
                selector.noteExternalFocus(id, now: now)
            }
            lastFrontWindow = id
            step.showCurrent = true
        }
        return step
    }

    /// One whole window poll, as the app runs it: Mission Control first, then the front window
    /// when `active` (tracking, not calibrating). For the replay and tests.
    public mutating func windowsUpdated(_ windows: [TrackedWindow], missionControlOpen open: Bool, front: Front,
                                        active: Bool, now: TimeInterval) -> FrontStep {
        _ = updateMissionControl(open, now: now)
        guard !missionControlOpen, active else { return FrontStep() }
        return adoptFront(front, windows: windows, now: now)
    }

    // MARK: Focus

    /// We asked for `id` to be focused (dwell or ⌃⌥⌘F).
    public mutating func focusRequested(_ id: CGWindowID, at time: TimeInterval) {
        lastFocusRequestAt = time
        lastFrontWindow = id
    }

    /// A request didn't take: let the next poll adopt what is really focused.
    public mutating func focusUnverified() { lastFocusRequestAt = -.infinity }

    /// ⌃⌥⌘F chose `id`.
    public mutating func manualFocus(_ id: CGWindowID, now: TimeInterval) {
        selector.noteManualFocus(id, now: now)
    }

    /// A recenter or anchor on `id`: it is the focused window, with no hold.
    public mutating func sync(_ id: CGWindowID?) {
        selector.syncCurrent(id)
        lastFrontWindow = id
    }
}
