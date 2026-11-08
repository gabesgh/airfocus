import XCTest
@testable import AirFocusCore

final class LookAwayDetectorTests: XCTestCase {
    let env = AngleEnvelope(yawMin: -15, yawMax: 15, pitchMin: -10, pitchMax: 5)
    let dt = 0.04   // 25 Hz

    /// Feeds a constant pose from t0 (inclusive) to t1 (exclusive); returns actions with times.
    @discardableResult
    func feed(_ d: inout LookAwayDetector, yaw: Double, pitch: Double = 0, speed: Double = 0,
              from t0: Double, to t1: Double, idle: (Double) -> Double = { _ in 1000 }) -> [(LookAwayDetector.Action, Double)] {
        var out: [(LookAwayDetector.Action, Double)] = []
        var i = 0
        while true {
            let t = t0 + Double(i) * dt
            if t >= t1 - 1e-9 { break }
            if let a = d.update(yaw: yaw, pitch: pitch, speed: speed, now: t, envelope: env, inputIdle: idle(t)) {
                out.append((a, t))
            }
            i += 1
        }
        return out
    }

    func testFacingTheScreenDoesNothing() {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 5, pitch: -2, from: 0, to: 30).isEmpty)
    }

    func testSidewaysTriggerAfterHold() throws {
        var d = LookAwayDetector()
        let actions = feed(&d, yaw: 60, from: 0, to: 8)
        let first = try XCTUnwrap(actions.first)
        XCTAssertEqual(first.0, .startScreenSaver)
        XCTAssertEqual(first.1, 5.0, accuracy: dt)
        XCTAssertEqual(actions.count, 1)
        XCTAssertTrue(d.isAway)
    }

    func testNotFarEnoughSideways() {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 40, from: 0, to: 10).isEmpty, "25° past the edge is under the 30° margin")
    }

    func testPitchUpTriggers() {
        var d = LookAwayDetector()
        XCTAssertEqual(feed(&d, yaw: 0, pitch: 31, from: 0, to: 6).first?.0, .startScreenSaver)
    }

    func testLookingDownIsIgnored() {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 0, pitch: -60, from: 0, to: 30).isEmpty)
    }

    func testDelaySettingIsHonoured() {
        var cfg = LookAwayDetector.Config()
        cfg.awayHold = 10
        var d = LookAwayDetector(config: cfg)
        XCTAssertEqual(feed(&d, yaw: 60, from: 0, to: 12).first?.1 ?? 0, 10, accuracy: dt)
    }

    func testInputVeto() throws {
        var d = LookAwayDetector()
        // Typing until t = 4 while turned away: input idle = t - 4 after that.
        let actions = feed(&d, yaw: 60, from: 0, to: 12, idle: { t in t < 4 ? 0.1 : t - 4 })
        let first = try XCTUnwrap(actions.first)
        // Not at 5 s (input 1 s ago); fires once the last input is 5 s old.
        XCTAssertEqual(first.1, 9.0, accuracy: dt)
    }

    func testContinuousInputNeverTriggers() {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 60, from: 0, to: 30, idle: { _ in 0.5 }).isEmpty)
    }

    func testFlickerUnderToleranceDoesNotResetTimer() throws {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 60, from: 0, to: 3).isEmpty)
        XCTAssertTrue(feed(&d, yaw: 0, from: 3, to: 3.2).isEmpty)     // 0.2 s glance back
        let a = try XCTUnwrap(feed(&d, yaw: 60, from: 3.2, to: 8).first)
        XCTAssertEqual(a.1, 5.0, accuracy: dt)
    }

    func testLongerReturnResetsTimer() throws {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 60, from: 0, to: 3).isEmpty)
        XCTAssertTrue(feed(&d, yaw: 0, from: 3, to: 3.5).isEmpty)     // 0.5 s back
        let a = try XCTUnwrap(feed(&d, yaw: 60, from: 3.5, to: 10).first)
        XCTAssertEqual(a.1, 8.5, accuracy: dt)
    }

    func testLookBackWakesAfterSettledHold() throws {
        var d = LookAwayDetector()
        feed(&d, yaw: 60, from: 0, to: 6)
        XCTAssertTrue(d.isAway)
        // Turning back fast: no wake while moving.
        XCTAssertTrue(feed(&d, yaw: 0, speed: 80, from: 6, to: 7).isEmpty)
        let wake = try XCTUnwrap(feed(&d, yaw: 0, from: 7, to: 8).first)
        XCTAssertEqual(wake.0, .wakeForUnlock)
        XCTAssertEqual(wake.1, 7.6, accuracy: dt * 1.5)
    }

    func testLookBackUsesGrownEnvelope() {
        var d = LookAwayDetector()
        feed(&d, yaw: 60, from: 0, to: 6)
        XCTAssertEqual(feed(&d, yaw: 24, from: 6, to: 7).first?.0, .wakeForUnlock, "9° past the edge is inside +10°")
        var d2 = LookAwayDetector()
        feed(&d2, yaw: 60, from: 0, to: 6)
        XCTAssertTrue(feed(&d2, yaw: 27, from: 6, to: 8).isEmpty)
    }

    func testWakeIsRateLimited() {
        var d = LookAwayDetector()
        feed(&d, yaw: 60, from: 0, to: 6)
        let wakes = feed(&d, yaw: 0, from: 6, to: 27).filter { $0.0 == .wakeForUnlock }
        XCTAssertEqual(wakes.count, 3)                               // 6.6, 16.6, 26.6
        XCTAssertEqual(wakes[1].1 - wakes[0].1, 10, accuracy: dt)
    }

    func testNoWakeUnlessWeStartedTheEpisode() {
        var d = LookAwayDetector()
        XCTAssertTrue(feed(&d, yaw: 0, from: 0, to: 15).isEmpty)
        XCTAssertFalse(d.isAway)
    }

    func testPitchOnlyLookBackAfterStreamRestart() throws {
        var d = LookAwayDetector()
        feed(&d, yaw: 60, from: 0, to: 6)
        // Stream restarted while away: yaw is now relative to an arbitrary new zero.
        d.markYawUnanchored()
        let wake = try XCTUnwrap(feed(&d, yaw: 140, pitch: -2, from: 6, to: 8).first)
        XCTAssertEqual(wake.0, .wakeForUnlock)
        // Pitch still has to be inside the grown band.
        var d2 = LookAwayDetector()
        feed(&d2, yaw: 60, from: 0, to: 6)
        d2.markYawUnanchored()
        XCTAssertTrue(feed(&d2, yaw: 0, pitch: 30, from: 6, to: 9).isEmpty)
        // Without the restart, a far-off yaw never counts as looking back.
        var d3 = LookAwayDetector()
        feed(&d3, yaw: 60, from: 0, to: 6)
        XCTAssertTrue(feed(&d3, yaw: 140, pitch: -2, from: 6, to: 9).isEmpty)
    }

    func testUnanchoredYawCannotTriggerSideways() {
        var d = LookAwayDetector()
        d.markYawUnanchored()
        XCTAssertTrue(feed(&d, yaw: 80, from: 0, to: 10).isEmpty)
        XCTAssertEqual(feed(&d, yaw: 80, pitch: 35, from: 10, to: 16).first?.0, .startScreenSaver)
        d.userReturned()
        d.markYawAnchored()
        XCTAssertEqual(feed(&d, yaw: 80, from: 20, to: 26).first?.0, .startScreenSaver)
    }

    func testUserReturnedEndsEpisode() {
        var d = LookAwayDetector()
        feed(&d, yaw: 60, from: 0, to: 6)
        XCTAssertTrue(d.isAway)
        d.userReturned()
        XCTAssertFalse(d.isAway)
        XCTAssertTrue(feed(&d, yaw: 0, from: 6, to: 20).isEmpty)
    }

    func testRemovingAirPodsOnlyCountsWhenOptedIn() {
        var off = LookAwayDetector()
        for i in 0..<500 {
            XCTAssertNil(off.updateDisconnected(now: Double(i) * dt, inputIdle: 1000, treatRemovalAsAway: false))
        }
        var on = LookAwayDetector()
        var fired: Double?
        for i in 0..<500 {
            let t = Double(i) * dt
            if on.updateDisconnected(now: t, inputIdle: 1000, treatRemovalAsAway: true) != nil, fired == nil { fired = t }
        }
        XCTAssertEqual(fired ?? 0, 10, accuracy: dt)
        // Same input veto.
        var vetoed = LookAwayDetector()
        for i in 0..<500 {
            XCTAssertNil(vetoed.updateDisconnected(now: Double(i) * dt, inputIdle: 2, treatRemovalAsAway: true))
        }
    }
}
