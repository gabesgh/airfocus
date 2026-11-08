import CoreMotion
import Foundation
import AirFocusCore

enum HeadEvent {
    case sample(HeadSample)
    case connected
    case disconnected
    /// The yaw reference jumped (bud switch or an unexplained step). UNVERIFIED heuristic.
    case referenceJump(String)
    /// First sample after a (re)start of the stream. CoreMotion picks a new arbitrary yaw zero
    /// every time the stream starts (R§1.5), so a stored calibration needs a recentre.
    case streamStarted(isRestart: Bool)
    case error(Error)
}

/// A source of head poses: the AirPods, or the mouse in simulation mode (spec §3.3).
/// Events are delivered on the main queue.
@MainActor
protocol HeadSource: AnyObject {
    var onEvent: ((HeadEvent) -> Void)? { get set }
    var isSimulated: Bool { get }
    var isRunning: Bool { get }
    /// Samples per second over the last second.
    var sampleRate: Double { get }
    /// Host uptime of the last sample (0 = never).
    var lastSampleUptime: TimeInterval { get }
    func start()
    func stop()
    func restart(reason: String)
}

/// CMHeadphoneMotionManager wrapper (R§1.8).
///
/// Motion only flows when the app is a bundled, signed .app with NSMotionUsageDescription, the
/// AirPods are connected, in the ears and the *current audio output*, and Motion & Fitness is
/// granted. When any of these fails the stream just goes quiet, hence the watchdog.
/// Background delivery to an LSUIElement agent is expected to work (Nod, Dorso, ...) but is
/// UNVERIFIED on the user's AirPods, as are the ~25 Hz rate and the angle sign conventions.
@MainActor
final class HeadTracker: NSObject, HeadSource, CMHeadphoneMotionManagerDelegate {
    var onEvent: ((HeadEvent) -> Void)?
    let isSimulated = false
    private(set) var isRunning = false
    private(set) var lastSampleUptime: TimeInterval = 0

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.gshimoon.airfocus.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    /// Only touched on the motion queue.
    nonisolated(unsafe) private var unwrapper = PoseUnwrapper()

    private var watchdog: Timer?
    private var restartBackoff: TimeInterval = 3
    private var lastRestart: TimeInterval = 0
    private var everHadSamples = false
    private var restartPending = false
    private var recentSamples: [TimeInterval] = []

    static var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }
    var isDeviceMotionAvailable: Bool { manager.isDeviceMotionAvailable }

    override init() {
        super.init()
        manager.delegate = self
    }

    var sampleRate: Double {
        let now = ProcessInfo.processInfo.systemUptime
        return Double(recentSamples.filter { now - $0 <= 1.0 }.count)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        manager.startConnectionStatusUpdates()     // delegate callbacks even before motion flows
        startMotion()
        Log.info(.motion, "motion start (available: \(manager.isDeviceMotionAvailable), auth: \(Self.authorization.label))")
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStall() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.invalidate(); watchdog = nil
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        recentSamples.removeAll()
        Log.info(.motion, "motion stop")
    }

    func restart(reason: String) {
        guard isRunning else { return }
        Log.info(.motion, "motion restart: \(reason)")
        manager.stopDeviceMotionUpdates()
        startMotion()
    }

    private func startMotion() {
        lastRestart = ProcessInfo.processInfo.systemUptime
        restartPending = true
        queue.addOperation { [weak self] in self?.unwrapper.reset() }
        guard manager.isDeviceMotionAvailable else {
            Log.error(.motion, "headphone motion not available on this Mac")
            return
        }
        // The first call from a bundled, signed app shows the Motion & Fitness prompt.
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let error {
                DispatchQueue.main.async { self.onEvent?(.error(error)) }
                return
            }
            guard let m = motion else { return }
            let a = m.attitude, r = m.rotationRate
            let out = self.unwrapper.process(yawRad: a.yaw, pitchRad: a.pitch, rollRad: a.roll,
                                             rotationRate: (r.x, r.y, r.z), timestamp: m.timestamp,
                                             sensor: m.sensorLocation.rawValue)
            let sample = HeadSample(yaw: out.yaw, pitch: out.pitch, roll: out.roll, speed: out.speed,
                                    deviceTime: m.timestamp, hostTime: now)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.deliver(sample, jump: out.jump) }
            }
        }
    }

    private func deliver(_ s: HeadSample, jump: PoseUnwrapper.Jump?) {
        guard isRunning else { return }
        lastSampleUptime = s.hostTime
        let wasRestart = everHadSamples
        everHadSamples = true
        restartBackoff = 3
        recentSamples.append(s.hostTime)
        if recentSamples.count > 120 { recentSamples.removeFirst(recentSamples.count - 120) }
        if restartPending {
            restartPending = false
            Log.info(.motion, wasRestart ? "samples resumed after restart; yaw reference is arbitrary again"
                                         : "first motion sample")
            onEvent?(.streamStarted(isRestart: wasRestart))
        }
        if let jump {
            let text: String
            switch jump {
            case .sensorSwitch(let dy, let dp): text = String(format: "streaming bud changed (Δyaw %.1f°, Δpitch %.1f°)", dy, dp)
            case .unexplainedYawStep(let dy): text = String(format: "unexplained yaw step %.1f°", dy)
            }
            Log.info(.motion, "reference jump: \(text)")
            onEvent?(.referenceJump(text))
        }
        onEvent?(.sample(s))
    }

    /// Samples stalled (AirPods not the active output, bud swap, sleep/wake): ask again, backing
    /// off so a disconnected headset doesn't cause a restart every 3 s forever.
    private func checkStall() {
        let now = ProcessInfo.processInfo.systemUptime
        let lastActivity = max(lastSampleUptime, lastRestart)
        guard isRunning, now - lastActivity > restartBackoff else { return }
        if everHadSamples && lastSampleUptime > lastRestart {
            Log.info(.motion, String(format: "motion stalled (%.1f s without samples)", now - lastSampleUptime))
        }
        restartBackoff = min(restartBackoff * 2, 30)
        restart(reason: "watchdog")
    }

    // MARK: CMHeadphoneMotionManagerDelegate (delivered on the motion queue)

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Log.info(.motion, "AirPods connected")
                self.onEvent?(.connected)
                // A request made before the headphones connected may never start sending (Nod).
                if ProcessInfo.processInfo.systemUptime - self.lastSampleUptime > 1 {
                    self.restartBackoff = 3
                    self.restart(reason: "headphones connected")
                }
            }
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Log.info(.motion, "AirPods disconnected")
                self.onEvent?(.disconnected)
            }
        }
    }
}

extension CMAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown (\(rawValue))"
        }
    }
}
