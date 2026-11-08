import CoreGraphics
import XCTest
@testable import AirFocusCore

/// A simulated head at the AirPods' 50 Hz, moving with the smooth bell-shaped speed of a real
/// head movement (minimum jerk): peak speed = 1.875 × amplitude / duration.
private struct SimulatedHead {
    static let dt = 0.02
    var detector = FlickDetector()
    var envelope: AngleEnvelope? = AngleEnvelope(yawMin: -12, yawMax: 10, pitchMin: -18, pitchMax: -8)
    var yaw = 0.0
    var pitch = -12.0
    var time = 100.0
    var yawAnchored = true
    var secondsSinceKey = 100.0
    var gyroScale = 1.0
    var bursts: [FlickDetector.Burst] = []

    var fired: [FlickDetector.Direction] { bursts.filter(\.fired).compactMap(\.direction) }
    var rejections: [FlickDetector.Rejection] { bursts.compactMap(\.rejection) }

    mutating func hold(_ seconds: Double) {
        for _ in 0..<Int(seconds / Self.dt) { feed(speed: 1) }
    }

    mutating func move(yaw dYaw: Double = 0, pitch dPitch: Double = 0, over seconds: Double) {
        let startYaw = yaw, startPitch = pitch
        let steps = max(1, Int(seconds / Self.dt))
        var previous = 0.0
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let s = t * t * t * (10 - 15 * t + 6 * t * t)
            let degrees = hypot(dYaw, dPitch) * (s - previous)
            previous = s
            yaw = startYaw + dYaw * s
            pitch = startPitch + dPitch * s
            feed(speed: degrees / Self.dt * gyroScale)
        }
    }

    mutating func jumpInTime(_ seconds: Double) { time += seconds }

    private mutating func feed(speed: Double) {
        time += Self.dt
        if let b = detector.update(yaw: yaw, pitch: pitch, speed: speed, time: time, envelope: envelope,
                                   yawAnchored: yawAnchored, secondsSinceKey: secondsSinceKey) {
            bursts.append(b)
        }
    }
}

final class FlickDetectorTests: XCTestCase {
    func testSharpFlickLeftAndRight() {
        var left = SimulatedHead()
        left.hold(0.5)
        left.move(yaw: 20, over: 0.14)
        left.hold(0.5)
        XCTAssertEqual(left.fired, [.left])

        var right = SimulatedHead()
        right.hold(0.5)
        right.move(yaw: -20, over: 0.14)
        right.hold(0.5)
        XCTAssertEqual(right.fired, [.right])
    }

    func testOutAndBackFiresOnce() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 20, over: 0.14)
        h.move(yaw: -20, over: 0.16)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [.left], "coming back isn't a flick the other way")
    }

    func testLookingAtAnotherWindowNeverFires() {
        for (degrees, seconds) in [(10.0, 0.5), (15.0, 0.4), (20.0, 0.35), (25.0, 0.3), (-25.0, 0.3)] {
            var h = SimulatedHead()
            h.hold(0.5)
            h.move(yaw: degrees, over: seconds)
            h.hold(1)
            XCTAssertEqual(h.fired, [], "\(degrees)° in \(seconds) s is a glance")
        }
    }

    func testAFullTurnIsNotAFlick() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 80, over: 0.34)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .large)
    }

    func testASlowTurnIsNotAFlick() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 60, over: 1)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
    }

    func testASmallTwitchIsNotAFlick() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 8, over: 0.06)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
    }

    func testDiagonalIsNotAFlick() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 20, pitch: 15, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .diagonal)
    }

    func testFlickUpFromScreenHeightFires() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(pitch: 14, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [.up])
    }

    func testLookingUpFromTheKeyboardNeverFires() {
        var h = SimulatedHead()
        h.pitch = -35
        h.hold(0.5)
        h.move(pitch: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .offScreen)
    }

    func testAnUpFlickThatStaysOnTheScreenDoesNotFire() {
        var h = SimulatedHead()
        h.pitch = -19
        h.hold(0.5)
        h.move(pitch: 10, over: 0.12)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .belowTop)
    }

    func testDownwardNeverFires() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(pitch: -15, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .down)
    }

    func testComingBackFromLookingAwayNeverFires() {
        var h = SimulatedHead()
        h.yaw = 40
        h.hold(0.5)
        h.move(yaw: -20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .offScreen)
    }

    func testUnanchoredYawBlocksSideFlicksOnly() {
        var h = SimulatedHead()
        h.yawAnchored = false
        h.hold(0.5)
        h.move(yaw: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.rejections.first, .unanchored)
        h.move(yaw: -20, over: 1)
        h.hold(0.5)
        h.move(pitch: 14, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [.up], "pitch is gravity-referenced, so it doesn't need an anchor")
    }

    func testTypingHoldsFlicks() {
        var h = SimulatedHead()
        h.secondsSinceKey = 0.1
        h.hold(0.5)
        h.move(yaw: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .typing)
    }

    func testAnAttitudeStepWithoutGyroDoesNotFire() {
        var h = SimulatedHead()
        h.gyroScale = 0.05
        h.hold(0.5)
        h.move(yaw: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
        XCTAssertEqual(h.rejections.first, .noGyro)
    }

    func testCooldownThenASecondFlick() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 14, over: 0.1)
        h.hold(0.4)
        h.move(yaw: 14, over: 0.1)
        h.hold(0.1)
        XCTAssertEqual(h.fired, [.left])
        XCTAssertEqual(h.rejections.first, .cooldown, "the Dock drops a key sent while a Desktop is arriving")
        h.move(yaw: -28, over: 1)
        h.hold(1.5)
        h.move(yaw: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [.left, .left])
    }

    func testAGapDropsTheBurst() {
        var h = SimulatedHead()
        h.hold(0.5)
        h.move(yaw: 8, over: 0.06)
        h.jumpInTime(0.5)
        h.move(yaw: 12, over: 0.08)
        XCTAssertEqual(h.fired.count, 0, "half a flick either side of a gap isn't one")
    }

    func testWithoutAnEnvelopeNothingFires() {
        var h = SimulatedHead()
        h.envelope = nil
        h.hold(0.5)
        h.move(yaw: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [])
    }

    func testTheTwoTogglesAreIndependent() {
        var h = SimulatedHead()
        h.detector.config.upEnabled = false
        h.hold(0.5)
        h.move(pitch: 14, over: 0.14)
        h.hold(0.1)
        XCTAssertEqual(h.rejections, [.turnedOff])
        h.move(pitch: -14, over: 1)
        h.move(yaw: 20, over: 0.14)
        h.hold(0.5)
        XCTAssertEqual(h.fired, [.left], "a flick up that's turned off doesn't start the cooldown")

        var other = SimulatedHead()
        other.detector.config.sidewaysEnabled = false
        other.hold(0.5)
        other.move(yaw: 20, over: 0.14)
        other.hold(0.1)
        XCTAssertEqual(other.rejections, [.turnedOff])
        other.move(yaw: -20, over: 1)
        other.move(pitch: 14, over: 0.14)
        other.hold(0.5)
        XCTAssertEqual(other.fired, [.up])
    }

    func testSensitivityMidpointIsTheDefaults() {
        let plain = FlickDetector.Config(), mid = FlickDetector.Config(sensitivity: 0.5)
        XCTAssertEqual(mid.yawPeakRate, plain.yawPeakRate)
        XCTAssertEqual(mid.pitchPeakRate, plain.pitchPeakRate)
        XCTAssertEqual(mid.yawAmplitude, plain.yawAmplitude)
        XCTAssertEqual(mid.pitchAmplitude, plain.pitchAmplitude)
    }

    func testSensitivityIsMonotonicAndClamped() {
        let levels = stride(from: 0.0, through: 1.0, by: 0.05).map { FlickDetector.Config(sensitivity: $0) }
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThan(a.yawPeakRate, b.yawPeakRate)
            XCTAssertGreaterThan(a.pitchPeakRate, b.pitchPeakRate)
            XCTAssertGreaterThan(a.yawAmplitude.lowerBound, b.yawAmplitude.lowerBound)
            XCTAssertLessThanOrEqual(b.yawAmplitude.lowerBound, b.yawAmplitude.upperBound)
        }
        XCTAssertEqual(FlickDetector.Config(sensitivity: -3).yawPeakRate, FlickDetector.Config(sensitivity: 0).yawPeakRate)
        XCTAssertEqual(FlickDetector.Config(sensitivity: 9).yawPeakRate, FlickDetector.Config(sensitivity: 1).yawPeakRate)
    }

    func testLightCatchesWhatTheMidpointMisses() {
        for (sensitivity, expected) in [(0.5, [FlickDetector.Direction]()), (1.0, [.left])] {
            var h = SimulatedHead()
            h.detector.config = FlickDetector.Config(sensitivity: sensitivity)
            h.hold(0.5)
            h.move(yaw: 18, over: 0.2)      // peak ~169°/s
            h.hold(0.5)
            XCTAssertEqual(h.fired, expected, "sensitivity \(sensitivity)")
        }
    }
}

final class DesktopShortcutTests: XCTestCase {
    func testAbsentOrUnsetEntriesUseTheSystemDefault() throws {
        // What this Mac stores: enabled, with no key of its own.
        for hotkeys in [nil, [:], ["79": ["enabled": true], "81": ["enabled": true]]] as [[String: Any]?] {
            XCTAssertEqual(DesktopShortcut.resolve(hotkeys, left: true)?.keyCode, 123)
            XCTAssertEqual(DesktopShortcut.resolve(hotkeys, left: false)?.keyCode, 124)
        }
        let flags = try XCTUnwrap(DesktopShortcut.resolve(nil, left: true)).eventFlags
        XCTAssertEqual(flags, 0xA40000, "control + fn + numeric pad, the form that moved the Desktop on 26.7.1")
    }

    func testAShortcutThatsOffIsNeverPosted() {
        XCTAssertNil(DesktopShortcut.resolve(["79": ["enabled": false]], left: true))
        XCTAssertNil(DesktopShortcut.resolve(["81": ["enabled": 0]], left: false))
    }

    func testACustomKeyIsUsed() throws {
        let hotkeys: [String: Any] = ["81": ["enabled": true, "value": ["parameters": [65535, 18, 262144], "type": "standard"]]]
        let s = try XCTUnwrap(DesktopShortcut.resolve(hotkeys, left: false))
        XCTAssertEqual(s.keyCode, 18)
        XCTAssertEqual(s.eventFlags, 262144, "only arrow keys take the numeric pad flag")
    }

    func testAnEntryWithNoKeyIsNotPosted() {
        let hotkeys: [String: Any] = ["79": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]]]
        XCTAssertNil(DesktopShortcut.resolve(hotkeys, left: true))
    }
}

final class MissionControlDetectionTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)
    let apps: [pid_t: WindowFilter.AppInfo] = [
        50: .init(bundleID: "com.apple.dock", name: "Dock"),
        60: .init(bundleID: "com.example.app", name: "App"),
    ]

    private func entry(pid: pid_t, layer: Int, frame: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: 1, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: frame.dictionaryRepresentation, kCGWindowAlpha as String: 1.0]
    }

    private func isOpen(_ raw: [[String: Any]]) -> Bool {
        WindowFilter.filter(raw, ownPID: 1, screensCG: [screen], appInfo: { self.apps[$0] }).missionControlOpen
    }

    func testTheDocksFullScreenLayer18WindowMeansOpen() {
        // The list seen on 26.7.1 with Mission Control open.
        XCTAssertTrue(isOpen([entry(pid: 50, layer: 20, frame: screen), entry(pid: 50, layer: 20, frame: screen),
                              entry(pid: 50, layer: 18, frame: screen)]))
    }

    func testAnythingElseMeansClosed() {
        XCTAssertFalse(isOpen([]))
        XCTAssertFalse(isOpen([entry(pid: 50, layer: 20, frame: screen)]), "the Dock itself")
        XCTAssertFalse(isOpen([entry(pid: 60, layer: 18, frame: screen)]), "not the Dock")
        XCTAssertFalse(isOpen([entry(pid: 50, layer: 18, frame: CGRect(x: 0, y: 0, width: 200, height: 80))]), "not full screen")
    }

    func testFlickSettingsDefaultAndFallBack() throws {
        let suite = "AirFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.flickUpEnabled)
        XCTAssertTrue(settings.flickSidewaysEnabled)
        XCTAssertEqual(settings.flickSensitivity, 0.5)
        defaults.set(7.0, forKey: SettingsKey.flickSensitivity)
        XCTAssertEqual(settings.flickSensitivity, 0.5, "out of range falls back")
        settings.flickSensitivity = 0.2
        settings.flickUpEnabled = false
        settings.restoreAppearanceAndSensitivity()
        XCTAssertEqual(settings.flickSensitivity, 0.5)
        XCTAssertTrue(settings.flickUpEnabled)
    }
}
