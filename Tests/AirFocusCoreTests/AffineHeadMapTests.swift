import CoreGraphics
import XCTest
@testable import AirFocusCore

/// Ground truth used by several tests: ~60 pt per degree of yaw (turning left moves left),
/// ~110 pt per degree of pitch (looking up moves up), a little cross-talk, centred on a 2560×1440 screen.
let truth = AffineHeadMap(a: [1280, -60, 4], b: [720, -3, -110])

func sample(_ yaw: Double, _ pitch: Double, map: AffineHeadMap = truth) -> CalibrationSample {
    CalibrationSample(yaw: yaw, pitch: pitch, screen: map.point(yaw: yaw, pitch: pitch))
}

/// Deterministic pseudo-random noise (LCG), so the noisy tests are reproducible.
struct Noise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Double {          // uniform in [-1, 1)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }
    mutating func gaussian(_ sigma: Double) -> Double {   // sum of uniforms, close enough
        (0..<6).reduce(0.0) { acc, _ in acc + next() } / 6.0 * 2.45 * sigma
    }
}

final class AffineHeadMapTests: XCTestCase {
    func testExactRecovery() throws {
        let s = [sample(-15, 5), sample(15, 5), sample(0, -5), sample(-10, -4), sample(12, 3)]
        let m = try XCTUnwrap(AffineHeadMap.fit(s))
        for (got, want) in zip(m.a + m.b, truth.a + truth.b) {
            XCTAssertEqual(got, want, accuracy: 0.5)
        }
        for p in s {
            let q = m.point(yaw: p.yaw, pitch: p.pitch)
            XCTAssertLessThan(Geometry.distance(q, p.screen), 1.0)
        }
        let r = m.residuals(s)
        XCTAssertLessThan(r.rmsPoints, 1.0)
        XCTAssertLessThan(r.meanDegrees, 0.02)
    }

    func testFitNeedsThreePoints() {
        XCTAssertNil(AffineHeadMap.fit([sample(0, 0), sample(5, 5)]))
    }

    func testNoisyFitResidual() throws {
        var noise = Noise()
        var s: [CalibrationSample] = []
        for yaw in stride(from: -15.0, through: 15.0, by: 7.5) {
            for pitch in [-5.0, 0, 5] {
                // The user's head lands within ~0.5° of where it should be.
                let measured = CalibrationSample(yaw: yaw + noise.gaussian(0.5), pitch: pitch + noise.gaussian(0.5),
                                                 screen: truth.point(yaw: yaw, pitch: pitch))
                s.append(measured)
            }
        }
        let m = try XCTUnwrap(AffineHeadMap.fit(s))
        let r = m.residuals(s)
        // Residual reflects the injected noise (σ = 0.5° per axis → mean distance ~0.6°), not more.
        XCTAssertGreaterThan(r.meanDegrees, 0.2)
        XCTAssertLessThan(r.meanDegrees, 1.2)
        // The fitted map stays close to the truth across the screen.
        for (yaw, pitch) in [(-12.0, 4.0), (0.0, 0.0), (12.0, -4.0)] {
            XCTAssertLessThan(Geometry.distance(m.point(yaw: yaw, pitch: pitch), truth.point(yaw: yaw, pitch: pitch)), 40)
        }
    }

    func testCollinearWindowsAloneAreIllConditionedButSupplementFixesIt() throws {
        // Four terminals side by side: dots in one row (pitch varies only by noise).
        var noise = Noise(state: 42)
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let rowYaw = [-15.0, -5, 5, 15]
        let row = rowYaw.map { y -> CalibrationSample in
            CalibrationSample(yaw: y + noise.gaussian(0.3), pitch: 0 + noise.gaussian(0.3),
                              screen: truth.point(yaw: y, pitch: 0))
        }
        let rowOnly = try XCTUnwrap(AffineHeadMap.fit(row))
        let offRow = truth.point(yaw: 0, pitch: 5)     // a point well above the row
        let rowOnlyError = Geometry.distance(rowOnly.point(yaw: 0, pitch: 5), offRow)
        XCTAssertGreaterThan(rowOnlyError, 150, "a row alone cannot determine the vertical mapping")

        // The plan adds supplementary screen points for the collinear case.
        let plan = CalibrationPlan.make(windows: row.enumerated().map { (CGWindowID($0.offset + 1), $0.element.screen) },
                                        screensCG: [screen])
        XCTAssertTrue(plan.reasons.collinearY)
        let supplements = plan.points.filter { if case .screen = $0.kind { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(supplements.count, 4)
        let supplementSamples = supplements.map { p -> CalibrationSample in
            let a = truth.angles(for: p.pointCG)!
            return CalibrationSample(yaw: a.yaw + noise.gaussian(0.3), pitch: a.pitch + noise.gaussian(0.3), screen: p.pointCG)
        }
        let both = try XCTUnwrap(AffineHeadMap.fit(row + supplementSamples))
        XCTAssertLessThan(Geometry.distance(both.point(yaw: 0, pitch: 5), offRow), 40)
    }

    func testRecenterMapsCurrentPoseOntoTarget() throws {
        var m = truth
        let target = CGPoint(x: 900, y: 500)
        m.recenter(yaw: 3, pitch: -2, onto: target)
        XCTAssertLessThan(Geometry.distance(m.point(yaw: 3, pitch: -2), target), 1e-9)
        // Only the offset moved: the slopes are unchanged.
        XCTAssertEqual(Array(m.a[1...]), Array(truth.a[1...]))
        XCTAssertEqual(Array(m.b[1...]), Array(truth.b[1...]))
    }

    func testCalibrationRecenterShiftsAnchorsConsistently() throws {
        let samples = [sample(-15, 5), sample(15, 5), sample(0, -5)]
        let dot = truth.point(yaw: 10, pitch: 2)
        var cal = try XCTUnwrap(HeadCalibration.fit(samples: samples,
                                                    anchors: [WindowAnchor(windowID: 7, dotCG: dot, yaw: 10, pitch: 2)],
                                                    displayKey: "k", ridge: 0))
        // Simulate 6° of yaw drift: looking at the dot now reads yaw 16.
        cal.recenter(yaw: 16, pitch: 2, onto: dot)
        XCTAssertLessThan(Geometry.distance(cal.map.point(yaw: 16, pitch: 2), dot), 1e-6)
        XCTAssertEqual(cal.anchors[0].yaw, 16, accuracy: 1e-6)
        XCTAssertEqual(cal.anchors[0].pitch, 2, accuracy: 1e-6)
        // Every stored sample still maps onto its own target under the new map.
        for s in cal.samples {
            XCTAssertLessThan(Geometry.distance(cal.map.point(yaw: s.yaw, pitch: s.pitch), s.screen), 1)
        }
    }

    func testReanchorYawRestoresYawAndKeepsPitch() throws {
        let s = [sample(-15, 5), sample(15, 5), sample(0, -5), sample(-10, -4), sample(12, 3)]
        var cal = try XCTUnwrap(HeadCalibration.fit(samples: s, anchors: [], displayKey: "k"))
        // A new stream: the same physical head direction now reads 37° more yaw.
        let applied = cal.reanchorYaw(yaw: 5 + 37, pitch: 2, onto: truth.point(yaw: 5, pitch: 2))
        XCTAssertEqual(applied, -37, accuracy: 0.05)
        for (y, p) in [(-12.0, 4.0), (0, 0), (14, -3)] {
            XCTAssertLessThan(Geometry.distance(cal.map.point(yaw: y + 37, pitch: p), truth.point(yaw: y, pitch: p)), 1.0)
        }
        XCTAssertEqual(cal.samples[0].yaw, -15 + 37, accuracy: 0.05)
        XCTAssertEqual(cal.samples[0].pitch, 5, accuracy: 1e-9)
    }

    func testNudgeIsCappedAndPartial() throws {
        var cal = try XCTUnwrap(HeadCalibration.fit(samples: [sample(-15, 5), sample(15, 5), sample(0, -5)],
                                                    anchors: [], displayKey: "k", ridge: 0))
        let target = truth.point(yaw: 0, pitch: 0)
        // Pose reads 2° off; a 15% nudge is 0.3°, under the 0.5° cap.
        let applied = cal.nudge(yaw: 2, pitch: 0, towards: target, fraction: 0.15, maxDegrees: 0.5)
        XCTAssertEqual(applied, 0.3, accuracy: 1e-6)
        // A large error is capped at 0.5°.
        var cal2 = try XCTUnwrap(HeadCalibration.fit(samples: [sample(-15, 5), sample(15, 5), sample(0, -5)],
                                                     anchors: [], displayKey: "k", ridge: 0))
        XCTAssertEqual(cal2.nudge(yaw: 20, pitch: 0, towards: target, fraction: 0.15, maxDegrees: 0.5), 0.5, accuracy: 1e-6)
    }

    func testEnvelopeInversion() throws {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 2560, y: 1440), CGPoint(x: 1000, y: 300)] {
            let a = try XCTUnwrap(truth.angles(for: corner))
            XCTAssertLessThan(Geometry.distance(truth.point(yaw: a.yaw, pitch: a.pitch), corner), 1e-6)
        }
        let env = try XCTUnwrap(truth.envelope(screensCG: [screen]))
        // Yaw decreases to the right, pitch decreases downwards: bounding box of the 4 corners.
        let tl = truth.angles(for: CGPoint(x: 0, y: 0))!
        let br = truth.angles(for: CGPoint(x: 2560, y: 1440))!
        XCTAssertEqual(env.yawMax, max(tl.yaw, truth.angles(for: CGPoint(x: 0, y: 1440))!.yaw), accuracy: 1e-9)
        XCTAssertEqual(env.yawMin, min(br.yaw, truth.angles(for: CGPoint(x: 2560, y: 0))!.yaw), accuracy: 1e-9)
        XCTAssertGreaterThan(env.yawMax - env.yawMin, 40)     // 2560 pt at ~60 pt/° ≈ 43°
        XCTAssertGreaterThan(env.pitchMax - env.pitchMin, 12) // 1440 pt at ~110 pt/° ≈ 13°
        XCTAssertTrue(env.contains(yaw: 0, pitch: 0))
        XCTAssertFalse(env.contains(yaw: 40, pitch: 0))
    }

    func testSingularMapHasNoInverseOrEnvelope() {
        let flat = AffineHeadMap(a: [0, 10, 20], b: [0, 1, 2])   // rows proportional
        XCTAssertNil(flat.angles(for: .zero))
        XCTAssertNil(flat.envelope(screensCG: [CGRect(x: 0, y: 0, width: 100, height: 100)]))
    }

    func testGapDisambiguationUsesAnchorsWithinFourDegrees() throws {
        let left = TrackedWindow(id: 1, frameCG: CGRect(x: 100, y: 200, width: 900, height: 900))
        let right = TrackedWindow(id: 2, frameCG: CGRect(x: 1500, y: 200, width: 900, height: 900))
        let cal = try XCTUnwrap(HeadCalibration.fit(
            samples: [sample(-15, 5), sample(15, 5), sample(0, -5)],
            anchors: [WindowAnchor(windowID: 1, dotCG: left.targetPointCG, yaw: 13, pitch: 1)],
            displayKey: "k"))
        // Near the measured anchor of window 1 → window 1.
        XCTAssertEqual(cal.nearestWindowByAngle(yaw: 11, pitch: 0, windows: [left, right]), 1)
        // Far from every dot → nothing.
        XCTAssertNil(cal.nearestWindowByAngle(yaw: 0, pitch: 0, windows: [left, right]))
        // Window 2 has no anchor: its dot goes through the inverse map.
        let a2 = try XCTUnwrap(cal.map.angles(for: right.targetPointCG))
        XCTAssertEqual(cal.nearestWindowByAngle(yaw: a2.yaw + 1, pitch: a2.pitch, windows: [left, right]), 2)
    }

    func testStoreRoundTripPerDisplayKey() throws {
        let suite = "AirFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalibrationStore(defaults: defaults)
        let cal = try XCTUnwrap(HeadCalibration.fit(samples: [sample(-15, 5), sample(15, 5), sample(0, -5)],
                                                    anchors: [], displayKey: "A"))
        store.save(cal)
        XCTAssertEqual(store.load(displayKey: "A"), cal)
        XCTAssertNil(store.load(displayKey: "B"))
        store.clear(displayKey: "A")
        XCTAssertNil(store.load(displayKey: "A"))
    }
}
