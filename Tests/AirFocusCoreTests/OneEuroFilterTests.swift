import XCTest
@testable import AirFocusCore

final class OneEuroFilterTests: XCTestCase {
    let rate = 25.0

    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(12.5, at: 0), 12.5)
    }

    func testConvergesToAStep() {
        var f = OneEuroFilter()
        _ = f.filter(0, at: 0)
        var out = 0.0
        for i in 1...50 { out = f.filter(10, at: Double(i) / rate) }   // 2 s after a 10° step
        XCTAssertEqual(out, 10, accuracy: 0.05)
    }

    func testSmoothsJitterAtRest() {
        var f = OneEuroFilter()
        var noise = Noise(state: 7)
        var outSq = 0.0, rawSq = 0.0
        for i in 0..<250 {
            let raw = 5 + noise.next() * 0.5     // ±0.5° jitter
            let out = f.filter(raw, at: Double(i) / rate)
            if i > 25 { outSq += (out - 5) * (out - 5); rawSq += (raw - 5) * (raw - 5) }
        }
        XCTAssertLessThan(outSq.squareRoot(), rawSq.squareRoot() * 0.6, "RMS jitter should drop well below the input's")
    }

    func testLagDuringFastTurnIsBounded() {
        // 40°/s turn: the filter must keep up (β raises the cutoff with speed).
        var fast = OneEuroFilter()
        var noBeta = OneEuroFilter(minCutoff: 1.0, beta: 0, dCutoff: 1.0)
        var lagFast = 0.0, lagNoBeta = 0.0
        for i in 0...25 {
            let t = Double(i) / rate
            let v = 40 * t
            lagFast = v - fast.filter(v, at: t)
            lagNoBeta = v - noBeta.filter(v, at: t)
        }
        XCTAssertLessThan(lagFast, 3.0, "lag at 40°/s should stay within a few degrees")
        XCTAssertLessThan(lagFast, lagNoBeta, "β must reduce lag compared with a fixed cutoff")
    }

    func testResetAfterLongGap() {
        var f = OneEuroFilter()
        _ = f.filter(0, at: 0)
        _ = f.filter(0, at: 0.04)
        XCTAssertEqual(f.filter(30, at: 5.0), 30, "a gap longer than maxGap restarts the filter")
    }

    func testPoseFilterFiltersBothAxes() {
        var f = HeadPoseFilter()
        _ = f.filter(yaw: 0, pitch: 0, at: 0)
        let out = f.filter(yaw: 10, pitch: -10, at: 0.04)
        XCTAssertGreaterThan(out.yaw, 0); XCTAssertLessThan(out.yaw, 10)
        XCTAssertLessThan(out.pitch, 0); XCTAssertGreaterThan(out.pitch, -10)
    }
}
