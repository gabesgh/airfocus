import AppKit
import AirFocusCore

/// Wires LookAwayDetector to the screen saver, the lock state and the overlay (R§9, R§11.6, spec §2.6).
///
/// Away: start the screen saver (or lock, if opted in), hide the overlay, pause focusing and, on
/// AC power, hold off idle system sleep. Look back: wake at most every 10 s and only for an episode
/// this app started. The user unlocks with their own password or Touch ID.
@MainActor
final class LookAwayController {
    private(set) var detector = LookAwayDetector()
    private let session: SessionStateObserver
    private let settings: AppSettings
    /// True from the moment we start the screen saver until the user is back and unlocked.
    private(set) var episodeActive = false
    private var engaged = false          // the saver/lock/display-sleep was actually observed
    private var episodeID = 0

    /// true = went away (hide overlay, pause focusing); false = user returned (restore, recentre).
    var onEpisodeChange: ((Bool) -> Void)?

    init(session: SessionStateObserver, settings: AppSettings) {
        self.session = session
        self.settings = settings
    }

    /// Feed a filtered pose (only while the feature is enabled and its prerequisites hold).
    func feed(yaw: Double, pitch: Double, speed: Double, now: TimeInterval, envelope: AngleEnvelope) {
        detector.config.awayHold = settings.lookAwayDelay
        let idle = KeyActivity.secondsSinceUserInput
        if let action = detector.update(yaw: yaw, pitch: pitch, speed: speed, now: now, envelope: envelope, inputIdle: idle) {
            act(action)
        }
    }

    /// Feed once a second while no motion arrives (AirPods out / disconnected).
    func feedNoMotion(now: TimeInterval) {
        if let action = detector.updateDisconnected(now: now, inputIdle: KeyActivity.secondsSinceUserInput,
                                                    treatRemovalAsAway: settings.treatRemovalAsAway) {
            Log.info(.lookAway, "AirPods removed for \(Int(detector.config.removalHold)) s with no input: treating as away")
            act(action)
        }
    }

    func markYawUnanchored() { detector.markYawUnanchored() }
    func markYawAnchored() { detector.markYawAnchored() }

    /// Feature switched off or tracking stopped.
    func reset() {
        if episodeActive { endEpisode(reason: "look-away disabled") }
        detector.reset()
    }

    private func act(_ action: LookAwayDetector.Action) {
        switch action {
        case .startScreenSaver:
            guard !episodeActive else { return }
            episodeActive = true
            engaged = session.isObscured
            episodeID += 1
            let id = episodeID
            if settings.lockImmediately && ScreenSaverControl.lockNow() {
                Log.info(.lookAway, "away: locked with SACLockScreenImmediate")
            } else {
                if settings.lockImmediately { Log.error(.lookAway, "SACLockScreenImmediate unavailable; starting the screen saver instead") }
                Log.info(.lookAway, "away for \(Int(settings.lookAwayDelay)) s: starting the screen saver")
                ScreenSaverControl.start()
            }
            ScreenSaverControl.preventIdleSleep()
            onEpisodeChange?(true)
            // Safety: if nothing engaged (launch failed), end the episode instead of pausing forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.episodeActive, self.episodeID == id else { return }
                    self.session.poll()
                    if !self.engaged && !self.session.isObscured && !self.session.displayAsleep {
                        Log.error(.lookAway, "screen saver did not start within 6 s; ending the away episode")
                        self.endEpisode(reason: "screen saver did not engage")
                    }
                }
            }
        case .wakeForUnlock:
            // Only for an episode we started, and only while something actually covers the screen.
            guard episodeActive else { return }
            guard session.displayAsleep || session.screenSaverRunning || ScreenSaverControl.isScreenLocked else { return }
            Log.info(.lookAway, "look back detected: waking for the unlock prompt")
            ScreenSaverControl.wakeForUnlock()
        }
    }

    /// Call on every session state change.
    func sessionChanged() {
        guard episodeActive else { return }
        if session.isObscured || session.displayAsleep { engaged = true; return }
        if engaged && !ScreenSaverControl.isScreenLocked {
            endEpisode(reason: "user returned and unlocked")
        }
    }

    private func endEpisode(reason: String) {
        Log.info(.lookAway, "away episode ended: \(reason)")
        episodeActive = false
        engaged = false
        detector.userReturned()
        ScreenSaverControl.allowIdleSleep()
        onEpisodeChange?(false)
    }
}
