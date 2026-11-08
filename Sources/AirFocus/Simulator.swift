import AppKit
import AirFocusCore

/// Developer › Simulate head with mouse (spec §3.3): the mouse position becomes synthetic yaw and
/// pitch (~40 pt per degree around the main screen's centre), speed comes from mouse velocity.
/// Everything downstream (calibration, filter, selector, focuser, overlay) is unchanged.
@MainActor
final class MouseHeadSource: HeadSource {
    var onEvent: ((HeadEvent) -> Void)?
    let isSimulated = true
    private(set) var isRunning = false
    private(set) var lastSampleUptime: TimeInterval = 0
    private var model = MouseHeadModel(centre: Screens.primaryCentreCG)
    private var timer: Timer?
    static let rate = 25.0

    var sampleRate: Double { isRunning ? Self.rate : 0 }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        model = MouseHeadModel(centre: Screens.primaryCentreCG)
        let t = Timer(timeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)    // keep running while a menu is open
        timer = t
        Log.info(.motion, "simulated head (mouse) start")
        onEvent?(.connected)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil
        Log.info(.motion, "simulated head (mouse) stop")
    }

    func restart(reason: String) {
        model = MouseHeadModel(centre: Screens.primaryCentreCG)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let p = Geometry.cgPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: Screens.primaryHeight)
        lastSampleUptime = now
        onEvent?(.sample(model.sample(mouse: p, at: now)))
    }
}
