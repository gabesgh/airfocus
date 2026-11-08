import CoreGraphics
import XCTest
@testable import AirFocusCore

final class CalibrationCaptureTests: XCTestCase {
    let dt = 0.04

    func testSettleThenAverage() throws {
        var c = CalibrationCapture()
        c.begin(at: 0)
        // Moving for 1 s: never leaves the settle phase.
        for i in 0..<25 {
            XCTAssertEqual(c.feed(yaw: Double(i), pitch: 0, speed: 30, now: Double(i) * dt), .none)
        }
        XCTAssertEqual(c.phase, .settling)
        // Still from t = 1.0: settles at 1.3, averages until 1.8.
        var captured: (CalibrationCapture.Measurement, Double)?
        var averagingFrom: Double?
        var noise = Noise(state: 3)
        for i in 25..<100 {
            let t = Double(i) * dt
            let e = c.feed(yaw: 10 + noise.next() * 0.2, pitch: -3 + noise.next() * 0.2, speed: 2, now: t)
            if averagingFrom == nil, c.phase == .averaging { averagingFrom = t }
            if case .captured(let m) = e { captured = (m, t); break }
        }
        XCTAssertEqual(try XCTUnwrap(averagingFrom), 1.3, accuracy: dt)
        let (m, t) = try XCTUnwrap(captured)
        XCTAssertGreaterThanOrEqual(t, 1.8)
        XCTAssertLessThan(t, 1.9)
        XCTAssertEqual(m.yaw, 10, accuracy: 0.15)
        XCTAssertEqual(m.pitch, -3, accuracy: 0.15)
        XCTAssertGreaterThanOrEqual(m.count, 12)
        XCTAssertLessThan(m.stdDev, 1)
        XCTAssertEqual(c.phase, .captured)
        XCTAssertEqual(c.progress(now: t), 1)
    }

    func testSettleNeedsContinuousStillness() {
        var c = CalibrationCapture()
        c.config.travelGrace = 0
        c.begin(at: 0)
        // Still for 0.24 s, a twitch, still again: settle timer restarts.
        for i in 0..<6 { _ = c.feed(yaw: 0, pitch: 0, speed: 1, now: Double(i) * dt) }
        _ = c.feed(yaw: 0, pitch: 0, speed: 20, now: 0.24)
        for i in 7..<13 { _ = c.feed(yaw: 0, pitch: 0, speed: 1, now: Double(i) * dt) }
        XCTAssertEqual(c.phase, .settling, "0.2 s of stillness since the twitch is under 300 ms")
        _ = c.feed(yaw: 0, pitch: 0, speed: 1, now: 0.6)
        XCTAssertEqual(c.phase, .averaging)
    }

    func testStillHeadWaitsForTravel() throws {
        var c = CalibrationCapture()
        c.begin(at: 0)
        // Still aimed at the previous dot for 2 s: nothing starts, however still it is.
        for i in 0..<50 {
            XCTAssertEqual(c.feed(yaw: 10, pitch: 2, speed: 1, now: Double(i) * dt), .none)
        }
        XCTAssertEqual(c.phase, .settling)
        XCTAssertEqual(c.progress(now: 2), 0)
        // Moves to the new dot and holds: the capture is of the new pose.
        var got: CalibrationCapture.Measurement?
        for i in 50..<100 {
            let moving = i < 60
            let yaw = moving ? 10 - Double(i - 50) : 0
            if case .captured(let m) = c.feed(yaw: yaw, pitch: 2, speed: moving ? 25 : 1, now: Double(i) * dt) { got = m; break }
        }
        XCTAssertEqual(try XCTUnwrap(got).yaw, 0, accuracy: 1e-9)
    }

    func testStillHeadCapturesAfterGrace() throws {
        var c = CalibrationCapture()
        c.begin(at: 0)
        // The dot is next to the last one, so the head never travels: grace 2.5 + settle 0.3 + average 0.5.
        var capturedAt: Double?
        for i in 0..<100 {
            let t = Double(i) * dt
            if case .captured = c.feed(yaw: 10, pitch: 2, speed: 1, now: t) { capturedAt = t; break }
        }
        let t = try XCTUnwrap(capturedAt)
        XCTAssertGreaterThanOrEqual(t, 3.3)
        XCTAssertLessThan(t, 3.45)
    }

    func testFirstPointIgnoresStreamStartJump() {
        var c = CalibrationCapture()
        c.begin(at: 0, expectTravel: false)
        // A 16° reference jump as the stream starts must not count as the head moving.
        for i in 0..<60 {
            _ = c.feed(yaw: i == 0 ? 0 : 16, pitch: 0, speed: 1, now: Double(i) * dt)
        }
        XCTAssertEqual(c.phase, .settling, "2.4 s in: still inside the grace period")
        _ = c.feed(yaw: 16, pitch: 0, speed: 1, now: 2.5)
        _ = c.feed(yaw: 16, pitch: 0, speed: 1, now: 2.81)
        XCTAssertEqual(c.phase, .averaging)
    }

    func testStdDevRejectAndRetry() throws {
        var c = CalibrationCapture()
        c.begin(at: 0)
        var events: [CalibrationCapture.Event] = []
        // Gyro reads "still" but the angle wanders ±2° (e.g. slow sway): must be rejected.
        for i in 0..<30 {
            let t = Double(i) * dt
            let e = c.feed(yaw: (i % 2 == 0) ? 2 : -2, pitch: 0, speed: 1, now: t)
            if e != .none { events.append(e) }
        }
        guard case .rejected(let sd)? = events.first else { return XCTFail("expected a reject, got \(events)") }
        XCTAssertGreaterThan(sd, 1)
        XCTAssertEqual(c.rejectCount, 1)
        XCTAssertNotEqual(c.phase, .captured)
        // Then the user holds still: the retry captures.
        var got: CalibrationCapture.Measurement?
        for i in 30..<80 {
            if case .captured(let m) = c.feed(yaw: 1, pitch: 1, speed: 1, now: Double(i) * dt) { got = m; break }
        }
        XCTAssertEqual(try XCTUnwrap(got).yaw, 1, accuracy: 1e-9)
    }

    func testTimeout() {
        var c = CalibrationCapture()
        c.begin(at: 0)
        var last: CalibrationCapture.Event = .none
        var i = 0
        while last == .none, i < 1000 {
            last = c.feed(yaw: Double(i % 7), pitch: 0, speed: 50, now: Double(i) * dt)   // never settles
            i += 1
        }
        XCTAssertEqual(last, .timedOut)
        XCTAssertEqual(Double(i - 1) * dt, 15, accuracy: dt + 1e-9)
        XCTAssertTrue(c.isFinished)
    }

    func testTimeoutWithoutSamples() {
        var c = CalibrationCapture()
        c.begin(at: 100)
        XCTAssertEqual(c.checkTimeout(now: 110), .none)
        XCTAssertEqual(c.checkTimeout(now: 115.1), .timedOut)
    }

    func testReturnCapturesImmediately() throws {
        var c = CalibrationCapture()
        c.begin(at: 0)
        XCTAssertNil(c.captureNow(), "nothing to average yet")
        var c2 = CalibrationCapture()
        c2.begin(at: 0)
        for i in 0..<20 { _ = c2.feed(yaw: 4, pitch: 2, speed: 30, now: Double(i) * dt) }   // still moving
        let m = try XCTUnwrap(c2.captureNow())
        XCTAssertEqual(m.yaw, 4, accuracy: 1e-9)
        XCTAssertEqual(m.pitch, 2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(m.count, 13, "only the last 500 ms")
        XCTAssertEqual(c2.phase, .captured)
    }
}

final class CalibrationPlanTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    func testGridOfWindowsNeedsNoSupplement() {
        let windows: [(id: CGWindowID, dot: CGPoint)] = [
            (1, CGPoint(x: 640, y: 360)), (2, CGPoint(x: 1920, y: 360)),
            (3, CGPoint(x: 640, y: 1080)), (4, CGPoint(x: 1920, y: 1080)),
        ]
        let plan = CalibrationPlan.make(windows: windows, screensCG: [screen])
        XCTAssertFalse(plan.reasons.any)
        XCTAssertEqual(plan.points.count, 4)
        // Left to right, then top to bottom.
        XCTAssertEqual(plan.points.compactMap(\.windowID), [1, 3, 2, 4])
    }

    func testFewerThanThreeWindowsAddsScreenPoints() {
        let plan = CalibrationPlan.make(windows: [(1, CGPoint(x: 700, y: 700)), (2, CGPoint(x: 1900, y: 400))],
                                        screensCG: [screen])
        XCTAssertTrue(plan.reasons.fewWindows)
        let screenPoints = plan.points.filter { $0.windowID == nil }
        XCTAssertEqual(screenPoints.count, 5)   // centre + four corners inset 15%
        XCTAssertTrue(screenPoints.contains { $0.pointCG == CGPoint(x: 384, y: 216) })
        XCTAssertTrue(screenPoints.contains { $0.pointCG == CGPoint(x: 2176, y: 1224) })
    }

    func testCollinearRowAddsScreenPoints() {
        let row: [(id: CGWindowID, dot: CGPoint)] = (0..<4).map { (CGWindowID($0 + 1), CGPoint(x: 320 + Double($0) * 640, y: 700)) }
        let plan = CalibrationPlan.make(windows: row, screensCG: [screen])
        XCTAssertTrue(plan.reasons.collinearY)
        XCTAssertFalse(plan.reasons.collinearX)
        XCTAssertEqual(plan.points.count, 9)
        // The centre point (1280, 720) is not within 60 pt of a dot, so it is kept.
        XCTAssertTrue(plan.points.contains { $0.kind == .screen(index: 0, role: .centre) })
    }

    func testSupplementSkipsPointsOnTopOfWindowDots() {
        let windows: [(id: CGWindowID, dot: CGPoint)] = [(1, CGPoint(x: 1280, y: 730))]
        let plan = CalibrationPlan.make(windows: windows, screensCG: [screen])
        XCTAssertFalse(plan.points.contains { $0.kind == .screen(index: 0, role: .centre) },
                       "the window dot already covers the centre")
        XCTAssertEqual(plan.points.count, 5)
    }

    func testEmptySecondScreenGetsItsOwnPoints() {
        let second = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let windows: [(id: CGWindowID, dot: CGPoint)] = [
            (1, CGPoint(x: 640, y: 360)), (2, CGPoint(x: 1920, y: 360)),
            (3, CGPoint(x: 640, y: 1080)), (4, CGPoint(x: 1920, y: 1080)),
        ]
        let plan = CalibrationPlan.make(windows: windows, screensCG: [screen, second])
        XCTAssertEqual(plan.reasons.emptyScreens, [1])
        let supplements = plan.points.filter { $0.windowID == nil }
        XCTAssertEqual(supplements.count, 5)
        XCTAssertTrue(supplements.allSatisfy { second.contains($0.pointCG) })
        // Ordering is global: the negative-x screen's points come first.
        XCTAssertTrue(second.contains(plan.points[0].pointCG))
    }

    func testCapAtTwelvePoints() {
        var many: [(id: CGWindowID, dot: CGPoint)] = []
        for i in 0..<20 {
            let x: Double = 100 + Double(i % 5) * 500
            let y: Double = 150 + Double(i / 5) * 350
            many.append((CGWindowID(i + 1), CGPoint(x: x, y: y)))
        }
        let second = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let plan = CalibrationPlan.make(windows: many, screensCG: [screen, second])
        XCTAssertEqual(plan.points.count, CalibrationPlan.maxPoints)
        XCTAssertEqual(plan.points.filter { $0.windowID == nil }.count, 5, "the empty screen keeps its points")
    }

    func testOrderingGroupsColumnsWithTolerance() {
        let pts = [CGPoint(x: 1010, y: 900), CGPoint(x: 1000, y: 100), CGPoint(x: 200, y: 500), CGPoint(x: 1020, y: 500)]
        let ordered = CalibrationPlan.order(pts.enumerated().map {
            CalibrationPoint(kind: .window(CGWindowID($0.offset)), pointCG: $0.element)
        })
        XCTAssertEqual(ordered.map(\.pointCG), [CGPoint(x: 200, y: 500), CGPoint(x: 1000, y: 100),
                                                CGPoint(x: 1020, y: 500), CGPoint(x: 1010, y: 900)])
    }
}
