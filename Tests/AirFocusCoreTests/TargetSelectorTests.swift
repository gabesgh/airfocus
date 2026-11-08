import CoreGraphics
import XCTest
@testable import AirFocusCore

final class TargetSelectorTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    // Two terminals sharing an edge at x = 1280.
    let a = TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 100, width: 1280, height: 1000))
    let b = TrackedWindow(id: 2, frameCG: CGRect(x: 1280, y: 100, width: 1280, height: 1000))

    func input(_ p: CGPoint, _ now: TimeInterval, speed: Double = 0, lastKey: TimeInterval = -100,
               pitch: Double = 0, windows: [TrackedWindow]? = nil,
               gap: ((Double, Double, [TrackedWindow]) -> CGWindowID?)? = nil) -> TargetSelector.Input {
        TargetSelector.Input(point: p, yaw: 0, pitch: pitch, speed: speed, now: now, lastKeyDown: lastKey,
                             windows: windows ?? [a, b], screensCG: [screen], lowestCalibratedPitch: -5,
                             gapResolver: gap)
    }

    /// Feed the same point at 25 Hz from t0 to t1; return the first switch and when it happened.
    func run(_ s: inout TargetSelector, _ p: CGPoint, from t0: Double, to t1: Double,
             speed: Double = 0, lastKey: TimeInterval = -100) -> (CGWindowID, Double)? {
        var t = t0
        while t <= t1 + 1e-9 {
            if let id = s.update(input(p, t, speed: speed, lastKey: lastKey)).switchTo { return (id, t) }
            t += 0.04
        }
        return nil
    }

    func testDwellBeforeSwitching() throws {
        var s = TargetSelector()
        let pB = CGPoint(x: 1900, y: 600)
        let first = s.update(input(pB, 0))
        XCTAssertNil(first.switchTo)
        XCTAssertEqual(first.pending, 2)
        let mid = s.update(input(pB, 0.2))
        XCTAssertNil(mid.switchTo)
        XCTAssertEqual(mid.pendingProgress, 0.2 / 0.45, accuracy: 1e-6)
        let done = try XCTUnwrap(run(&s, pB, from: 0.24, to: 1.0))
        XCTAssertEqual(done.0, 2)
        XCTAssertEqual(done.1, 0.48, accuracy: 0.05)
        XCTAssertEqual(s.current, 2)
    }

    func testDwellRestartsWhenCandidateChanges() {
        var s = TargetSelector()
        XCTAssertNil(run(&s, CGPoint(x: 1900, y: 600), from: 0, to: 0.3))
        // Back to A (no current yet → A is a fresh candidate); its dwell starts over.
        let r = run(&s, CGPoint(x: 600, y: 600), from: 0.32, to: 2)
        XCTAssertEqual(r?.0, 1)
        XCTAssertEqual(r?.1 ?? 0, 0.32 + 0.45, accuracy: 0.05)
    }

    func testHysteresisAtSharedEdge() {
        var s = TargetSelector()
        XCTAssertEqual(run(&s, CGPoint(x: 600, y: 600), from: 0, to: 1)?.0, 1)
        // 20 pt into B: inside A's grown area (max(40, 8% of 1280 = 102)): never switches.
        XCTAssertNil(run(&s, CGPoint(x: 1300, y: 600), from: 2, to: 4))
        // 150 pt into B: past the margin → switches after the dwell.
        XCTAssertEqual(run(&s, CGPoint(x: 1430, y: 600), from: 4, to: 5)?.0, 2)
    }

    func testCooldownBetweenSwitches() throws {
        var s = TargetSelector()
        let sw = try XCTUnwrap(run(&s, CGPoint(x: 1900, y: 600), from: 0, to: 1))
        XCTAssertEqual(sw.0, 2)
        // Immediately back to A: the dwell (0.45 s) completes before the cooldown (0.6 s) does.
        let back = try XCTUnwrap(run(&s, CGPoint(x: 300, y: 600), from: sw.1 + 0.04, to: sw.1 + 2))
        XCTAssertEqual(back.0, 1)
        XCTAssertGreaterThanOrEqual(back.1 - sw.1, 0.6 - 1e-9)
    }

    func testCooldownRejectIsReported() throws {
        var s = TargetSelector()
        let sw = try XCTUnwrap(run(&s, CGPoint(x: 1900, y: 600), from: 0, to: 1))
        var t = sw.1 + 0.04
        var sawCooldown = false
        while t < sw.1 + 0.6 {
            let d = s.update(input(CGPoint(x: 300, y: 600), t))
            if d.reject == .cooldown { sawCooldown = true }
            XCTAssertNil(d.switchTo)
            t += 0.04
        }
        XCTAssertTrue(sawCooldown)
    }

    func testTypingGuardHoldsTheSwitch() {
        var s = TargetSelector()
        let pB = CGPoint(x: 1900, y: 600)
        // Typing continuously (last key 0.1 s ago at every tick): no switch.
        var t = 0.0
        var reasons = Set<String>()
        while t < 2 {
            let d = s.update(input(pB, t, lastKey: t - 0.1))
            XCTAssertNil(d.switchTo)
            if let r = d.reject { reasons.insert(r.rawValue) }
            t += 0.04
        }
        XCTAssertTrue(reasons.contains("typing"))
        // Typing stops at t = 2.0: the switch waits until 0.7 s after the last key.
        let r = run(&s, pB, from: 2.0, to: 4, lastKey: 2.0)
        XCTAssertEqual(r?.0, 2)
        XCTAssertGreaterThanOrEqual(r?.1 ?? 0, 2.7 - 1e-9)
    }

    func testSettledHeadGate() {
        var s = TargetSelector()
        let pB = CGPoint(x: 1900, y: 600)
        XCTAssertNil(run(&s, pB, from: 0, to: 1, speed: 40))
        XCTAssertEqual(s.update(input(pB, 1.04, speed: 40)).reject, .moving)
        XCTAssertEqual(s.update(input(pB, 1.08, speed: 10)).switchTo, 2)
    }

    func testKeyboardGlanceReject() {
        var s = TargetSelector()
        // Lowest calibrated pitch is -5; -16 is 11° below it.
        for i in 0..<30 {
            let d = s.update(input(CGPoint(x: 1900, y: 600), Double(i) * 0.04, pitch: -16))
            XCTAssertNil(d.switchTo)
            XCTAssertEqual(d.reject, .keyboardGlance)
            XCTAssertNil(d.underPointer)
        }
        // -14 is only 9° below: allowed.
        XCTAssertEqual(s.update(input(CGPoint(x: 1900, y: 600), 2, pitch: -14)).pending, 2)
    }

    func testOffScreenReject() {
        var s = TargetSelector()
        XCTAssertEqual(s.update(input(CGPoint(x: -200, y: 600), 0)).reject, .offScreen)
        XCTAssertEqual(s.update(input(CGPoint(x: 1900, y: 1700), 0.04)).reject, .offScreen)
        // 100 pt outside: not off-screen, but no window either.
        XCTAssertEqual(s.update(input(CGPoint(x: -100, y: 600), 0.08)).reject, .noWindow)
    }

    func testHitTestUsesVisibleRegionFrontToBack() {
        let filtered = WindowFilter.filter(
            [win(9, x: 1500, y: 300, w: 600, h: 400), win(2, x: 1280, y: 100, w: 1280, h: 1000)],
            ownPID: 999, screensCG: [screen], appInfo: { _ in nil }).windows
        var s = TargetSelector()
        let d = s.update(input(CGPoint(x: 1700, y: 500), 0, windows: filtered))
        XCTAssertEqual(d.underPointer, 9, "the front window wins where they overlap")
        let d2 = s.update(input(CGPoint(x: 1350, y: 900), 0.04, windows: filtered))
        XCTAssertEqual(d2.underPointer, 2)
    }

    func testGapResolverIsUsedOnlyInGaps() {
        let left = TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 100, width: 1000, height: 1000))
        let right = TrackedWindow(id: 2, frameCG: CGRect(x: 1400, y: 100, width: 1000, height: 1000))
        var s = TargetSelector()
        let gap: (Double, Double, [TrackedWindow]) -> CGWindowID? = { _, _, _ in 2 }
        XCTAssertEqual(s.update(input(CGPoint(x: 1200, y: 600), 0, windows: [left, right], gap: gap)).underPointer, 2)
        XCTAssertEqual(s.update(input(CGPoint(x: 500, y: 600), 0.04, windows: [left, right], gap: gap)).underPointer, 1)
        XCTAssertEqual(s.update(input(CGPoint(x: 1200, y: 600), 0.08, windows: [left, right])).reject, .noWindow)
    }

    func testExternalFocusIsAdoptedAndNotFoughtBack() {
        var s = TargetSelector()
        XCTAssertEqual(run(&s, CGPoint(x: 1900, y: 600), from: 0, to: 1)?.0, 2)
        // The user clicks A while the (drifted) pointer still sits on B.
        s.noteExternalFocus(1, now: 2)
        XCTAssertEqual(s.current, 1)
        XCTAssertNil(run(&s, CGPoint(x: 1900, y: 600), from: 2, to: 5), "must not yank focus back to B")
        // Looking at A, then deliberately at B again: switches.
        _ = run(&s, CGPoint(x: 600, y: 600), from: 5, to: 5.2)
        XCTAssertEqual(run(&s, CGPoint(x: 1900, y: 600), from: 5.24, to: 7)?.0, 2)
    }

    func testSyncCurrentAdoptsWithoutHold() {
        var s = TargetSelector()
        // Tracking starts with A focused: adopt it, and a look at B still switches after the dwell
        // (unlike an external focus change, which holds until the pointer moves).
        s.syncCurrent(1)
        XCTAssertEqual(s.current, 1)
        XCTAssertEqual(run(&s, CGPoint(x: 1900, y: 600), from: 0, to: 1)?.0, 2)
    }

    func testHotkeyOnlyModeNeverSwitches() {
        var cfg = TargetSelector.Config()
        cfg.autoSwitch = false
        var s = TargetSelector(config: cfg)
        XCTAssertNil(run(&s, CGPoint(x: 1900, y: 600), from: 0, to: 3))
        XCTAssertEqual(s.update(input(CGPoint(x: 1900, y: 600), 3.1)).underPointer, 2)
        s.noteManualFocus(2, now: 3.1)
        XCTAssertEqual(s.current, 2)
    }
}

/// A synthetic CGWindowList entry.
func win(_ id: Int, pid: Int = 100, layer: Int = 0, x: Double, y: Double, w: Double, h: Double,
         alpha: Double = 1, owner: String? = "Terminal") -> [String: Any] {
    var d: [String: Any] = [
        kCGWindowNumber as String: NSNumber(value: id),
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowAlpha as String: NSNumber(value: alpha),
        kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as NSDictionary,
    ]
    if let owner { d[kCGWindowOwnerName as String] = owner }
    return d
}
