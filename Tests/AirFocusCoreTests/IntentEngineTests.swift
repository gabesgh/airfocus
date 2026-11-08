import CoreGraphics
import XCTest
@testable import AirFocusCore

/// A scripted head at 50 Hz feeding the intent engine, with minimum-jerk turns (peak speed 1.875 ×
/// amplitude / duration) and an optional slow sway. Yaw +8.9° is the middle of A, −1.1° the A/B edge.
private struct Head {
    static let dt = 0.02
    static let map = AffineHeadMap(a: [1244, -64, 3], b: [0, -2, -60])
    static let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let a = TrackedWindow(id: 1, pid: 1, appName: "A", frameCG: CGRect(x: 0, y: 25, width: 1280, height: 1415))
    static let b = TrackedWindow(id: 2, pid: 2, appName: "B", frameCG: CGRect(x: 1280, y: 25, width: 1280, height: 1415))
    static let top = TrackedWindow(id: 3, pid: 3, appName: "Top", frameCG: CGRect(x: 0, y: 25, width: 2560, height: 707))
    static let bottom = TrackedWindow(id: 4, pid: 4, appName: "Bottom", frameCG: CGRect(x: 0, y: 732, width: 2560, height: 708))
    static let edgeYaw = -1.125            // x = 1280 at pitch −12

    var engine = IntentEngine()
    var scene = IntentEngine.Scene(windows: [a, b], screensCG: [screen], map: map, lowestCalibratedPitch: -22)
    var t = 100.0
    var yaw = 8.9
    var pitch = -12.0
    /// Added to every pose: a drifted or restarted yaw zero, as the AirPods report it.
    var offset = (yaw: 0.0, pitch: 0.0)
    var gate: IntentEngine.Gate?
    var sway = 0.0
    var rng = SplitMix64(seed: 5)
    var switches: [(time: TimeInterval, to: CGWindowID)] = []
    var switchDecisions: [IntentEngine.Decision] = []
    var last = IntentEngine.Decision()

    init(current: CGWindowID? = 1, scene: IntentEngine.Scene? = nil) {
        if let scene { self.scene = scene }
        engine.adopt(current, at: t, hold: false)
    }

    mutating func feed(speed: Double) {
        t += Self.dt
        let y = yaw + offset.yaw + sway * rng.normal(), p = pitch + offset.pitch + sway * rng.normal() * 0.6
        last = engine.sample(time: t, yaw: y, pitch: p, speed: speed, scene: scene, gate: gate)
        if let to = last.switchTo { switches.append((t, to)); switchDecisions.append(last) }
    }

    mutating func hold(_ seconds: Double, typingEvery: Double? = nil, focused: TrackedWindow? = a) {
        var nextKey = t
        for _ in 0..<Int((seconds / Self.dt).rounded()) {
            if let every = typingEvery, t >= nextKey {
                engine.keyDown(at: t, focused: focused, scene: scene)
                nextKey = t + every
            }
            feed(speed: 2 + abs(rng.normal()))
        }
    }

    /// A deliberate turn; returns when the head settled (speed under 25°/s for good).
    @discardableResult
    mutating func turn(yaw dy: Double = 0, pitch dp: Double = 0, over seconds: Double, typingEvery: Double? = nil) -> TimeInterval {
        let y0 = yaw, p0 = pitch
        let steps = max(1, Int(seconds / Self.dt))
        var previous = 0.0, settled = t
        var nextKey = t
        for i in 1...steps {
            if let every = typingEvery, t >= nextKey {
                engine.keyDown(at: t, focused: Self.a, scene: scene)
                nextKey = t + every
            }
            let x = Double(i) / Double(steps)
            let s = x * x * x * (10 - 15 * x + 6 * x * x)
            let speed = hypot(dy, dp) * (s - previous) / Self.dt
            previous = s
            yaw = y0 + dy * s
            pitch = p0 + dp * s
            feed(speed: speed)
            if speed >= 25 { settled = t + Self.dt }
        }
        return settled
    }

    /// A slow creep, never faster than a couple of degrees a second.
    mutating func creep(yaw dy: Double, over seconds: Double) {
        let steps = Int(seconds / Self.dt)
        for _ in 0..<steps {
            yaw += dy / Double(steps)
            feed(speed: abs(dy) / seconds + abs(rng.normal()))
        }
    }

    mutating func click(at p: CGPoint) {
        engine.click(at: t, point: p, scene: scene)
    }

    var firstSwitch: (time: TimeInterval, to: CGWindowID)? { switches.first }
}

final class IntentEngineTests: XCTestCase {
    func testAFarCleanSettledShiftSwitchesAtLeastAsFastAsTheDwell() throws {
        var h = Head()
        h.hold(1.5)
        let settled = h.turn(yaw: -20, over: 0.38)
        h.hold(2)
        let sw = try XCTUnwrap(h.firstSwitch)
        XCTAssertEqual(sw.to, 2)
        XCTAssertLessThanOrEqual(sw.time - settled, 0.45, "today's dwell is 450 ms")
        XCTAssertEqual(h.switches.count, 1)
    }

    func testHoveringJustPastABoundaryNeverSwitches() {
        var h = Head()
        h.sway = 0.25
        h.hold(1)
        h.turn(yaw: Head.edgeYaw - 1 - h.yaw, over: 0.35)          // a real turn, landing 1° into B
        for _ in 0..<15 {
            h.hold(1.5)
            h.turn(yaw: h.rng.uniform(-1, 1) - (h.yaw - (Head.edgeYaw - 1)), over: 0.2)   // small readjustments
        }
        h.hold(5)
        XCTAssertTrue(h.switches.isEmpty, "\(h.switches)")
    }

    func testTypingRaisesTheBarButADeliberateHeldShiftStillGetsThrough() throws {
        var calm = Head()
        calm.hold(1.5)
        let calmSettled = calm.turn(yaw: -20, over: 0.38)
        calm.hold(4)
        let calmLatency = try XCTUnwrap(calm.firstSwitch).time - calmSettled

        var typing = Head()
        typing.hold(1.5, typingEvery: 0.15)
        let settled = typing.turn(yaw: -20, over: 0.38, typingEvery: 0.15)
        typing.hold(4, typingEvery: 0.15)
        let sw = try XCTUnwrap(typing.firstSwitch, "harder, not locked")
        XCTAssertEqual(sw.to, 2)
        XCTAssertGreaterThan(sw.time - settled, calmLatency + 0.15, "typing straight through the turn holds it off for a while")
        let bar = try XCTUnwrap(typing.switchDecisions.first).threshold / typing.engine.parameters.threshold
        XCTAssertGreaterThan(bar, 3, "the bar was about 4× when it went through")
    }

    /// Typing that stops, a turn, and a new burst in the new window: the new burst doesn't hold it back.
    func testANewBurstAfterTheTurnDoesNotHoldTheSwitch() throws {
        var h = Head()
        h.hold(1.5, typingEvery: 0.15)
        h.hold(1.0)                                   // finished typing, glanced over the output
        let settled = h.turn(yaw: -20, over: 0.38)
        h.hold(0.15)
        h.hold(2, typingEvery: 0.15, focused: Head.a)
        XCTAssertLessThan(try XCTUnwrap(h.firstSwitch).time - settled, 0.6)
    }

    func testSlowCreepCountsLittleButADeliberateTurnToTheSameSpotSwitches() {
        var creep = Head()
        creep.hold(1)
        creep.creep(yaw: Head.edgeYaw - 3 - creep.yaw, over: 9)    // 13° in 9 s, into B by 3°
        creep.hold(6)
        XCTAssertTrue(creep.switches.isEmpty, "drift isn't intent: \(creep.switches)")

        var turn = Head()
        turn.hold(1)
        let settled = turn.turn(yaw: Head.edgeYaw - 3 - turn.yaw, over: 0.35)
        turn.hold(2)
        XCTAssertEqual(turn.firstSwitch?.to, 2)
        XCTAssertLessThan((turn.firstSwitch?.time ?? .infinity) - settled, 1)
    }

    func testReferenceGlancesRaiseTheBarForThatPairOnly() {
        var h = Head()
        h.engine.parameters.typingFactor = 12           // so the glances themselves never switch
        for _ in 0..<5 {
            h.hold(2, typingEvery: 0.15)
            h.turn(yaw: -20, over: 0.38)
            h.hold(0.6)
            h.turn(yaw: 20, over: 0.38)
            h.hold(0.3)
            h.hold(1, typingEvery: 0.15)
        }
        XCTAssertTrue(h.switches.isEmpty)
        XCTAssertGreaterThanOrEqual(h.engine.glanceCount(from: 1, to: 2, at: h.t), 4)
        XCTAssertGreaterThan(h.engine.glanceMultiplier(from: 1, to: 2, t: h.t), 2.5)
        XCTAssertEqual(h.engine.glanceMultiplier(from: 1, to: 3, t: h.t), 1, "another pair is unaffected")
        XCTAssertEqual(h.engine.glanceMultiplier(from: 2, to: 1, t: h.t), 1, "and so is the way back")
    }

    /// A glance the engine fell for and the head undid, followed by typing, counts as a glance too.
    func testAnUndoneSwitchTeachesTheHabit() {
        var h = Head()
        h.engine.parameters.typingFactor = 1
        h.hold(2, typingEvery: 0.15)
        h.turn(yaw: -20, over: 0.38)
        h.hold(1.0)
        h.turn(yaw: 20, over: 0.38)
        h.hold(1.0)
        h.hold(0.5, typingEvery: 0.15)
        XCTAssertEqual(h.switches.map(\.to), [2, 1])
        XCTAssertEqual(h.engine.glanceCount(from: 1, to: 2, at: h.t), 1, accuracy: 0.01)
    }

    func testClicksTeachTheOffsetAndClicksWithoutLookingAreIgnored() {
        var h = Head()
        h.offset = (3, -1)                              // the AirPods' zero has drifted
        let points = [CGPoint(x: 640, y: 400), CGPoint(x: 1900, y: 900), CGPoint(x: 700, y: 1100), CGPoint(x: 2100, y: 300),
                      CGPoint(x: 1000, y: 700), CGPoint(x: 1600, y: 500)]
        for p in points {
            let target = Head.map.angles(for: p)!
            h.turn(yaw: target.yaw - h.yaw, pitch: target.pitch - h.pitch, over: 0.4)
            h.hold(0.5)
            h.click(at: p)
            h.hold(0.3)
        }
        XCTAssertEqual(h.engine.yaw.alpha, 3, accuracy: 0.6, "the yaw offset is learned")
        XCTAssertEqual(h.engine.pitch.alpha, -1, accuracy: 0.6)
        let notes = h.engine.drainNotes()
        XCTAssertEqual(notes.filter { if case .clickMeasured = $0 { return true }; return false }.count, points.count)

        // Clicking somewhere the head isn't pointing, 15° away: ignored.
        let before = h.engine.yaw.alpha
        h.click(at: CGPoint(x: h.engine.pointer(yaw: h.yaw + 3, pitch: h.pitch - 1, scene: h.scene).x - 960, y: 700))
        XCTAssertEqual(h.engine.yaw.alpha, before)
        XCTAssertTrue(h.engine.drainNotes().contains { if case .clickRejected = $0 { return true }; return false })
    }

    func testAClickWhileTheHeadMovesIsNotAMeasurement() {
        var h = Head()
        h.offset = (3, 0)
        h.hold(1)
        let before = h.engine.yaw.alpha
        h.turn(yaw: -10, over: 0.2)
        h.click(at: CGPoint(x: 1600, y: 700))
        XCTAssertEqual(h.engine.yaw.alpha, before)
        XCTAssertTrue(h.engine.drainNotes().isEmpty)
    }

    /// After a stream restart the yaw zero is arbitrary: no yaw-based switching until a settled click
    /// says where the head points, and that is logged, since it could stand in for ⌃⌥⌘R.
    func testUnknownYawAbstainsUntilAClickAnchorsIt() throws {
        var h = Head()
        h.offset = (25, 0)                              // the new stream's zero is somewhere else entirely
        h.engine.yawLost()
        XCTAssertFalse(h.engine.yawKnown)
        h.hold(1)
        h.turn(yaw: -20, over: 0.38)
        h.hold(3)
        XCTAssertTrue(h.switches.isEmpty, "side by side windows can't be told apart without yaw")
        XCTAssertNil(h.last.hovered)

        h.click(at: CGPoint(x: 1920, y: 720))
        XCTAssertTrue(h.engine.yawKnown)
        XCTAssertTrue(h.engine.drainNotes().contains { if case .clickAnchoredYaw = $0 { return true }; return false })
        h.engine.adopt(2, at: h.t, hold: false)        // the click focused B
        h.hold(1)
        h.turn(yaw: 20, over: 0.38)
        h.hold(2)
        XCTAssertEqual(h.firstSwitch?.to, 1, "anchored: switching works")
    }

    func testUnknownYawStillSwitchesOnPitch() throws {
        let stacked = IntentEngine.Scene(windows: [Head.top, Head.bottom], screensCG: [Head.screen], map: Head.map, lowestCalibratedPitch: -22)
        var h = Head(current: 3, scene: stacked)
        h.offset = (25, 0)
        h.engine.yawLost()
        h.pitch = -5                                  // y ≈ 320, in the top window
        h.hold(1)
        h.turn(pitch: -14, over: 0.38)                // y ≈ 1160, the bottom window
        h.hold(2)
        XCTAssertEqual(h.firstSwitch?.to, 4, "pitch is gravity-referenced")
    }

    func testTypingWithAStillHeadAnchorsAnUnknownYawWeakly() {
        var h = Head()
        h.offset = (25, 0)
        h.engine.yawLost()
        h.hold(1.5)
        h.hold(1, typingEvery: 0.15, focused: Head.a)
        XCTAssertTrue(h.engine.yawKnown)
        XCTAssertTrue(h.engine.drainNotes().contains(.typingAnchoredYaw))
        XCTAssertGreaterThan(h.engine.yaw.offsetVariance, 4, "weaker than a click")
    }

    /// Typing is one-sided: it says the head is somewhere in the focused window, so it only pulls
    /// when the pointer has drifted out of it.
    func testTypingPullsTheOffsetOnlyFromOutsideTheFocusedWindow() {
        var inside = Head()
        inside.offset = (2, 0)                          // drifted, but the pointer is still well inside A
        inside.hold(1)
        inside.hold(6, typingEvery: 0.2, focused: Head.a)
        XCTAssertEqual(inside.engine.yaw.alpha, 0, accuracy: 1e-9)

        var outside = Head()
        outside.yaw = Head.edgeYaw + 2                  // reading near A's right edge...
        outside.offset = (-5, 0)                        // ...and the pointer has drifted 3° into B
        outside.hold(1)
        outside.hold(20, typingEvery: 0.2, focused: Head.a)
        XCTAssertLessThan(outside.engine.yaw.alpha, -0.5, "pulled towards A")
        XCTAssertTrue(outside.switches.isEmpty)
    }

    func testEveryLiveGateHoldsSwitchingAndDropsTheEvidence() {
        for gate in [IntentEngine.Gate.missionControl, .flickHold, .away, .calibrating, .settings, .hotkeyOnly] {
            var h = Head()
            h.hold(1)
            h.gate = gate
            h.turn(yaw: -20, over: 0.38)
            h.hold(2)
            XCTAssertTrue(h.switches.isEmpty, "\(gate)")
            XCTAssertEqual(h.last.gate, gate)
            h.gate = nil
            h.feed(speed: 2)
            XCTAssertNil(h.last.switchTo, "\(gate): no switch the moment it lifts")
            XCTAssertLessThan(h.last.evidence, 3, "\(gate): evidence starts over")
        }
    }

    func testKeyboardGlanceAndOffScreenAreRejectsToo() {
        var down = Head()
        down.hold(1)
        down.turn(yaw: -20, pitch: -25, over: 0.4)    // past the lowest calibrated pitch by more than 10°
        down.hold(2)
        XCTAssertTrue(down.switches.isEmpty)
        XCTAssertEqual(down.last.gate, .keyboardGlance)

        var away = Head()
        away.hold(1)
        away.turn(yaw: -45, over: 0.5)                // far off the right edge
        away.hold(2)
        XCTAssertTrue(away.switches.isEmpty)
        XCTAssertEqual(away.last.gate, .offScreen)
    }

    func testAnAdoptedFocusIsHeldUntilTheHeadMoves() {
        var h = Head()
        h.hold(1)
        h.turn(yaw: -20, over: 0.38)                    // on B...
        h.engine.adopt(1, at: h.t, hold: true)         // ...but ⌘-Tab picked A
        h.hold(3)
        XCTAssertTrue(h.switches.isEmpty, "don't pull focus back to where the head happens to be")
    }

    func testTheEngineIsDeterministic() {
        func run() -> [String] {
            var h = Head()
            h.sway = 0.3
            h.offset = (1.5, -0.5)
            for i in 0..<12 {
                h.hold(1.2, typingEvery: i % 3 == 0 ? 0.15 : nil)
                h.turn(yaw: (i % 2 == 0 ? -20 : 20) + h.rng.uniform(-3, 3), over: 0.38)
                if i % 4 == 1 { h.click(at: CGPoint(x: 1900, y: 700)) }
            }
            return h.switches.map { "\($0.time) \($0.to)" } + ["\(h.engine.yaw.alpha) \(h.engine.sigma)"]
        }
        let a = run(), b = run()
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a.count, 3)
    }

    func testParametersByName() {
        let names = IntentEngine.Parameters.names.map(\.0)
        XCTAssertEqual(Set(names).count, names.count, "unique")
        var p = IntentEngine.Parameters()
        XCTAssertNil(p.apply(overrides: "threshold=20, typingFactor=3"))
        XCTAssertEqual(p.threshold, 20)
        XCTAssertEqual(p.typingFactor, 3)
        XCTAssertEqual(p.changes, "threshold=20.0,typingFactor=3.0")
        XCTAssertEqual(p.apply(overrides: "threshold=20,nonsense=1"), "nonsense=1")
        XCTAssertEqual(p.apply(overrides: "leak=fast"), "leak=fast")
        XCTAssertEqual(IntentEngine.Parameters().changes, "")
    }
}
