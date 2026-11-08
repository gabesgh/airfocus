import CoreGraphics
import XCTest
@testable import AirFocusCore

final class ThumbnailPickerTests: XCTestCase {
    let dt = 0.02
    // Frames seen on 26.7.1. The last two overlap by 55 pt.
    let frames = [CGRect(x: 20, y: 118, width: 496, height: 622), CGRect(x: 532, y: 614, width: 992, height: 622),
                  CGRect(x: 1540, y: 650, width: 496, height: 622), CGRect(x: 1540, y: 83, width: 496, height: 622)]
    let onFirst = CGPoint(x: 268, y: 429)

    private struct Run {
        var picker = ThumbnailPicker()
        var now = 100.0
        var picks = 0
        var last = ThumbnailPicker.Decision()

        mutating func hold(_ seconds: Double, at p: CGPoint, in frames: [CGRect], speed: Double = 1, inputIdle: Double = 100) {
            for _ in 0..<Int(seconds / 0.02) {
                now += 0.02
                last = picker.update(point: p, frames: frames, speed: speed, inputIdle: inputIdle, now: now)
                if last.pick { picks += 1 }
            }
        }
    }

    private func opened() -> Run {
        var r = Run()
        r.picker.begin(at: r.now)
        return r
    }

    func testHoldingPicksOnce() {
        var r = opened()
        r.hold(1.3, at: onFirst, in: frames)
        XCTAssertEqual(r.picks, 0, "still inside open settle + dwell")
        XCTAssertEqual(r.last.candidate, 0)
        r.hold(0.3, at: onFirst, in: frames)
        XCTAssertEqual(r.picks, 1)
        r.hold(3, at: onFirst, in: frames)
        XCTAssertEqual(r.picks, 1, "one pick per opening")
    }

    func testNothingCountsUntilItHasOpened() {
        var r = opened()
        r.hold(0.4, at: onFirst, in: frames)
        XCTAssertNil(r.last.candidate)
    }

    func testAMovingHeadDoesNotPick() {
        var r = opened()
        r.hold(3, at: onFirst, in: frames, speed: 60)
        XCTAssertEqual(r.picks, 0)
        XCTAssertEqual(r.last.progress, 0)
    }

    func testMovingToAnotherThumbnailStartsOver() {
        var r = opened()
        r.hold(1.2, at: onFirst, in: frames)
        r.hold(0.5, at: CGPoint(x: 1000, y: 900), in: frames)
        XCTAssertEqual(r.picks, 0)
        XCTAssertEqual(r.last.candidate, 1)
        r.hold(0.5, at: CGPoint(x: 1000, y: 900), in: frames)
        XCTAssertEqual(r.picks, 1)
    }

    func testOffEveryThumbnailNothingHappens() {
        var r = opened()
        r.hold(3, at: CGPoint(x: 800, y: 300), in: frames)
        XCTAssertEqual(r.picks, 0)
        XCTAssertNil(r.last.candidate)
        XCTAssertNil(r.last.progress)
    }

    func testASmallSlipOffTheEdgeKeepsTheHold() {
        var r = opened()
        r.hold(1.2, at: CGPoint(x: 500, y: 400), in: frames)
        r.hold(0.3, at: CGPoint(x: 525, y: 400), in: frames)   // 9 pt past the edge
        XCTAssertEqual(r.picks, 1)
    }

    func testOverlappingFramesPreferTheNearestCentre() {
        var r = opened()
        r.hold(0.6, at: CGPoint(x: 1800, y: 660), in: frames)  // in both; nearer the upper one's bottom
        XCTAssertEqual(r.last.candidate, 3, "the frame centres are 267 pt and 301 pt away")
    }

    func testUsingTheMouseHoldsThePick() {
        var r = opened()
        r.hold(3, at: onFirst, in: frames, inputIdle: 0.1)
        XCTAssertEqual(r.picks, 0)
        XCTAssertEqual(r.last.progress, 0)
    }

    func testAnAnimatingThumbnailDoesNotPick() {
        var r = opened()
        for i in 0..<150 {
            let moving = [frames[0].offsetBy(dx: CGFloat(i) * 5, dy: 0)]
            r.hold(0.02, at: CGPoint(x: moving[0].midX, y: moving[0].midY), in: moving)
        }
        XCTAssertEqual(r.picks, 0)
    }

    func testAGapInTheSamplesDoesNotCountAsHolding() {
        var r = opened()
        r.hold(0.6, at: onFirst, in: frames)
        r.now += 5
        r.hold(0.1, at: onFirst, in: frames)
        XCTAssertEqual(r.picks, 0)
    }

    func testReopeningAllowsAnotherPick() {
        var r = opened()
        r.hold(2, at: onFirst, in: frames)
        XCTAssertEqual(r.picks, 1)
        r.picker.begin(at: r.now)
        r.hold(2, at: onFirst, in: frames)
        XCTAssertEqual(r.picks, 2)
    }
}

final class AdoptWithHoldTests: XCTestCase {
    let left = TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 0, width: 600, height: 800))
    let middle = TrackedWindow(id: 2, frameCG: CGRect(x: 700, y: 0, width: 600, height: 800))
    let right = TrackedWindow(id: 3, frameCG: CGRect(x: 1400, y: 0, width: 600, height: 800))

    private func run(_ s: inout TargetSelector, x: CGFloat, from start: TimeInterval, seconds: TimeInterval) -> [CGWindowID] {
        var switched: [CGWindowID] = []
        var t = start
        while t < start + seconds {
            let input = TargetSelector.Input(point: CGPoint(x: x, y: 400), yaw: 0, pitch: 0, speed: 1, now: t, lastKeyDown: -100,
                                             windows: [left, middle, right], screensCG: [CGRect(x: 0, y: 0, width: 2000, height: 900)],
                                             lowestCalibratedPitch: nil)
            if let id = s.update(input).switchTo { switched.append(id) }
            t += 0.02
        }
        return switched
    }

    func testAPickHoldsEvenWhenItIsTheWindowAlreadyInFocus() {
        // After a Mission Control pick the head still aims where the thumbnail was.
        var s = TargetSelector()
        s.syncCurrent(left.id)
        s.adoptWithHold(left.id, now: 0)
        XCTAssertEqual(run(&s, x: 1000, from: 0, seconds: 3), [], "a pick must not be undone by a head that hasn't moved")
        XCTAssertEqual(s.current, left.id)
    }

    func testTheHoldEndsWhenTheHeadMovesToAnotherWindow() {
        var s = TargetSelector()
        s.adoptWithHold(left.id, now: 0)
        XCTAssertEqual(run(&s, x: 1000, from: 0, seconds: 2), [])
        XCTAssertEqual(run(&s, x: 1700, from: 2, seconds: 2), [right.id])
    }
}
