import CoreGraphics
import XCTest
@testable import AirFocusCore

final class WindowFilterTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let ownPID: pid_t = 4242

    // PIDs → bundle ids, mirroring what was seen on this Mac with Stage Manager on (R§3.3).
    let apps: [pid_t: WindowFilter.AppInfo] = [
        100: .init(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        101: .init(bundleID: "app.zen-browser.zen", name: "Zen"),
        102: .init(bundleID: "com.apple.MobileSMS", name: "Messages"),
        200: .init(bundleID: "com.apple.WindowManager", name: "WindowManager"),
        201: .init(bundleID: "com.apple.controlcenter", name: "Control Center"),
        202: .init(bundleID: nil, name: "WindowServer"),
        203: .init(bundleID: "com.apple.notificationcenterui", name: "Notification Center"),
        4242: .init(bundleID: "com.gshimoon.airfocus", name: "AirFocus"),
    ]

    func filter(_ raw: [[String: Any]], screens: [CGRect]? = nil) -> WindowFilterResult {
        WindowFilter.filter(raw, ownPID: ownPID, screensCG: screens ?? [screen], appInfo: { self.apps[$0] })
    }

    func testRealisticStageManagerListKeepsOnlyRealWindows() {
        let raw: [[String: Any]] = [
            win(1, pid: 4242, layer: 1000, x: 0, y: 0, w: 2560, h: 1440),          // our overlay panel
            win(2, pid: 201, layer: 25, x: 2300, y: 0, w: 40, h: 24),              // status item
            win(3, pid: 202, layer: 24, x: 0, y: 0, w: 2560, h: 24),               // menu bar
            win(4, pid: 203, layer: -2_147_483_601, x: 0, y: 0, w: 2560, h: 1440), // notification centre
            win(5, pid: 200, x: 10, y: 300, w: 200, h: 200),                       // "App Icon Window"
            win(6, pid: 200, x: 0, y: 0, w: 2560, h: 1440),                        // "Gesture Blocking Overlay"
            win(7, pid: 200, x: 1e9, y: 1e9, w: 1, h: 1),                          // parked 1×1
            win(8, pid: 100, x: -40, y: 400, w: 75, h: 98),                        // iTerm2 strip thumbnail
            win(9, pid: 102, x: -60, y: 600, w: 94, h: 161),                       // Messages strip thumbnail
            win(10, pid: 101, x: 200, y: 31, w: 1080, h: 1409),                    // Zen: the real window
            win(11, pid: 100, x: 1300, y: 100, w: 1200, h: 800),                   // iTerm2 window
        ]
        let r = filter(raw)
        XCTAssertEqual(r.windows.map(\.id), [10, 11])
        XCTAssertEqual(r.windows.map(\.appName), ["Zen", "iTerm2"])
        XCTAssertEqual(r.rejections[.notNormalLayer], 4)
        XCTAssertEqual(r.rejections[.ignoredOwner], 3)
        XCTAssertEqual(r.rejections[.tooSmall], 2)
        XCTAssertEqual(r.rawCount, raw.count)
        // The WindowManager full-screen overlay must not count as an occluder.
        XCTAssertEqual(r.windows[0].visibleFraction, 1, accuracy: 1e-9)
    }

    func testOwnWindowsAreExcludedAtAnyLayer() {
        let r = filter([win(1, pid: 4242, x: 100, y: 100, w: 800, h: 600),
                        win(2, pid: 100, x: 100, y: 100, w: 800, h: 600)])
        XCTAssertEqual(r.windows.map(\.id), [2])
        XCTAssertEqual(r.rejections[.ownProcess], 1)
        XCTAssertEqual(r.windows[0].visibleFraction, 1, accuracy: 1e-9, "our window never occludes")
    }

    // While Settings is open its window and the colour panel cover what's behind them (but are still
    // never tracked), so no dot lands on them.
    func testSettingsWindowOccludesWithoutBeingTrackedWhileOpen() throws {
        let settings = CGRect(x: 100, y: 100, width: 560, height: 640)
        let raw = [win(1, pid: 4242, x: 100, y: 100, w: 560, h: 640),
                   win(2, pid: 100, x: 100, y: 100, w: 1200, h: 800)]
        let r = WindowFilter.filter(raw, ownPID: ownPID, screensCG: [screen], ownWindowsOcclude: true, appInfo: { self.apps[$0] })
        let w = try XCTUnwrap(r.windows.first)
        XCTAssertEqual(r.windows.map(\.id), [2])
        XCTAssertEqual(r.rejections[.ownProcess], 1)
        XCTAssertLessThan(w.visibleFraction, 1)
        XCTAssertFalse(settings.contains(w.targetPointCG), "the dot must not land on Settings: \(w.targetPointCG)")
        XCTAssertFalse(w.visibleContains(CGPoint(x: settings.midX, y: settings.midY)))
    }

    func testColourPanelOccludesWhileSettingsIsOpen() throws {
        let panel = CGRect(x: 500, y: 300, width: 300, height: 400)
        let raw = [win(1, pid: 4242, layer: 3, x: 500, y: 300, w: 300, h: 400),
                   win(2, pid: 100, x: 400, y: 200, w: 500, h: 600)]
        let r = WindowFilter.filter(raw, ownPID: ownPID, screensCG: [screen], ownWindowsOcclude: true, appInfo: { self.apps[$0] })
        let w = try XCTUnwrap(r.windows.first)
        XCTAssertEqual(r.windows.map(\.id), [2])
        XCTAssertFalse(panel.contains(w.targetPointCG))
    }

    func testAWindowFullyBehindSettingsIsNotTracked() {
        let raw = [win(1, pid: 4242, x: 100, y: 100, w: 800, h: 700),
                   win(2, pid: 100, x: 200, y: 200, w: 400, h: 300)]
        let r = WindowFilter.filter(raw, ownPID: ownPID, screensCG: [screen], ownWindowsOcclude: true, appInfo: { self.apps[$0] })
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertEqual(r.rejections[.occluded], 1)
    }

    func testOverlayPanelsStatusItemAndMenusNeverOcclude() throws {
        // The full-screen overlay panel would otherwise hide every window on the screen.
        for layer in [1000, 25, 101] {
            let raw = [win(1, pid: 4242, layer: layer, x: 0, y: 0, w: 2560, h: 1440),
                       win(2, pid: 100, x: 100, y: 100, w: 800, h: 600)]
            let r = WindowFilter.filter(raw, ownPID: ownPID, screensCG: [screen], ownWindowsOcclude: true, appInfo: { self.apps[$0] })
            XCTAssertEqual(try XCTUnwrap(r.windows.first).visibleFraction, 1, accuracy: 1e-9, "layer \(layer)")
        }
    }

    func testShrunkenStageManagerCopyOffScreenIsRejected() {
        // Big enough, but mostly off the left edge (a parked stage).
        let r = filter([win(1, pid: 100, x: -900, y: 200, w: 1000, h: 700)])
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertEqual(r.rejections[.offScreen], 1)
    }

    func testTransparentWindowsAreSkipped() {
        let r = filter([win(1, pid: 100, x: 100, y: 100, w: 800, h: 600, alpha: 0)])
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertEqual(r.rejections[.transparent], 1)
    }

    func testOcclusionFractionAndDotInsideVisiblePart() throws {
        let r = filter([
            win(1, pid: 100, x: 0, y: 0, w: 1000, h: 1000),      // front
            win(2, pid: 101, x: 500, y: 0, w: 1000, h: 1000),    // right half visible
            win(3, pid: 102, x: 100, y: 100, w: 800, h: 800),    // fully hidden behind 1
        ])
        XCTAssertEqual(r.windows.map(\.id), [1, 2])
        let w2 = try XCTUnwrap(r.windows.last)
        XCTAssertEqual(w2.visibleFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(w2.targetPointCG.x, 1250, accuracy: 1e-9)
        XCTAssertEqual(w2.targetPointCG.y, 500, accuracy: 1e-9)
        XCTAssertFalse(w2.visibleContains(CGPoint(x: 700, y: 500)), "covered by window 1")
        XCTAssertTrue(w2.visibleContains(CGPoint(x: 1200, y: 500)))
        XCTAssertEqual(r.rejections[.occluded], 1)
    }

    func testSmallWindowsStillOcclude() {
        // A 150×99 palette in front hides almost 90% of a 160×105 window behind it.
        let r = filter([win(1, pid: 100, x: 100, y: 100, w: 150, h: 99),
                        win(2, pid: 101, x: 100, y: 100, w: 160, h: 105)])
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertEqual(r.rejections[.tooSmall], 1)
        XCTAssertEqual(r.rejections[.occluded], 1)
    }

    func testNameFallsBackToOwnerNameThenPID() {
        let r = WindowFilter.filter([win(1, pid: 555, x: 0, y: 0, w: 800, h: 600, owner: "Ghostty"),
                                     win(2, pid: 556, x: 1000, y: 0, w: 800, h: 600, owner: nil)],
                                    ownPID: ownPID, screensCG: [screen], appInfo: { _ in nil })
        XCTAssertEqual(r.windows.map(\.appName), ["Ghostty", "pid 556"])
    }

    func testMalformedEntriesAreCounted() {
        let r = filter([["kCGWindowNumber": NSNumber(value: 1)]])
        XCTAssertEqual(r.rejections[.malformed], 1)
    }

    func testWindowSpanningTwoScreensIsClippedPerScreen() throws {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let r = filter([win(1, pid: 100, x: -500, y: 100, w: 1000, h: 600)], screens: [screen, left])
        let w = try XCTUnwrap(r.windows.first)
        XCTAssertEqual(w.visibleFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(w.visibleRects.count, 2)
    }
}

final class GeometryTests: XCTestCase {
    // Primary 2560×1440 with the menu bar; a 1920×1080 display to its left whose top sits 200 pt
    // higher. CG frame (-1920, -200); AppKit frame (-1920, 560).
    let primaryHeight: CGFloat = 1440
    let primaryAppKit = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let secondaryAppKit = CGRect(x: -1920, y: 560, width: 1920, height: 1080)
    let secondaryCG = CGRect(x: -1920, y: -200, width: 1920, height: 1080)

    func testTwoMonitorConversionWithNegativeOrigin() {
        XCTAssertEqual(Geometry.cgRect(fromAppKit: primaryAppKit, primaryHeight: primaryHeight),
                       CGRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(Geometry.cgRect(fromAppKit: secondaryAppKit, primaryHeight: primaryHeight), secondaryCG)
        XCTAssertEqual(Geometry.appKitRect(fromCG: secondaryCG, primaryHeight: primaryHeight), secondaryAppKit)
        // The top-left corner of the secondary display.
        XCTAssertEqual(Geometry.appKitPoint(fromCG: CGPoint(x: -1920, y: -200), primaryHeight: primaryHeight),
                       CGPoint(x: -1920, y: 1640))
        XCTAssertEqual(Geometry.cgPoint(fromAppKit: CGPoint(x: -1920, y: 1640), primaryHeight: primaryHeight),
                       CGPoint(x: -1920, y: -200))
        // A window on the secondary display round-trips.
        let w = CGRect(x: -1500, y: -100, width: 800, height: 600)
        let back = Geometry.cgRect(fromAppKit: Geometry.appKitRect(fromCG: w, primaryHeight: primaryHeight),
                                   primaryHeight: primaryHeight)
        XCTAssertEqual(back, w)
    }

    func testPanelLocalPointOnSecondaryDisplay() {
        // The overlay panel for the secondary display sits at its AppKit origin.
        let p = Geometry.localPoint(fromCG: CGPoint(x: -1820, y: -100), panelOrigin: secondaryAppKit.origin,
                                    primaryHeight: primaryHeight)
        XCTAssertEqual(p, CGPoint(x: 100, y: 980))   // 100 pt from its left, 100 pt below its top
        let r = Geometry.localRect(fromCG: CGRect(x: -1920, y: -200, width: 100, height: 50),
                                   panelOrigin: secondaryAppKit.origin, primaryHeight: primaryHeight)
        XCTAssertEqual(r, CGRect(x: 0, y: 1030, width: 100, height: 50))
    }

    func testSubtractAndVisibleRegion() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pieces = Geometry.subtract(CGRect(x: 25, y: 25, width: 50, height: 50), from: r)
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces.reduce(0) { $0 + Geometry.area($1) }, 10_000 - 2_500, accuracy: 1e-9)
        XCTAssertEqual(Geometry.subtract(CGRect(x: 200, y: 200, width: 5, height: 5), from: r), [r])
        XCTAssertTrue(Geometry.visibleRegion(of: r, occludedBy: [CGRect(x: -10, y: -10, width: 200, height: 200)]).isEmpty)
    }

    func testVisibleCentreFallsBackForLShapes() throws {
        // Window 1000×1000 with its top-right 900×900 covered: an L along the left and bottom edges.
        let pieces = Geometry.visibleRegion(of: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                            occludedBy: [CGRect(x: 100, y: 0, width: 900, height: 900)])
        let c = try XCTUnwrap(Geometry.visibleCentre(of: pieces))
        XCTAssertTrue(pieces.contains { $0.contains(c) }, "the dot must land on the visible part")
    }

    func testDistanceToRects() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(Geometry.distance(from: CGPoint(x: 50, y: 50), to: r), 0)
        XCTAssertEqual(Geometry.distance(from: CGPoint(x: 130, y: 140), to: r), 50, accuracy: 1e-9)
        XCTAssertEqual(Geometry.distance(from: .zero, toAnyOf: []), .infinity)
    }

    func testEnvelopeGrowAndContains() {
        let e = AngleEnvelope(yawMin: -10, yawMax: 10, pitchMin: -5, pitchMax: 5)
        XCTAssertFalse(e.contains(yaw: 15, pitch: 0))
        XCTAssertTrue(e.grown(by: 10).contains(yaw: 15, pitch: 0))
        XCTAssertTrue(e.containsPitch(4))
    }

    func testDisplayConfigurationKeyIsOrderIndependent() {
        let a = DisplayInfo(id: 1, vendor: 1552, model: 44_000, serial: 7, frameCG: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let b = DisplayInfo(id: 5, frameCG: secondaryCG)
        XCTAssertEqual(DisplayConfiguration(displays: [a, b]).key, DisplayConfiguration(displays: [b, a]).key)
        XCTAssertNotEqual(DisplayConfiguration(displays: [a]).key, DisplayConfiguration(displays: [a, b]).key)
        XCTAssertTrue(DisplayConfiguration(displays: [b]).key.contains("id5@-1920,-200,1920x1080"))
    }
}

final class HeadPoseTests: XCTestCase {
    let deg = Double.pi / 180

    func testYawUnwrapsAcross180() {
        var u = PoseUnwrapper()
        var outs: [Double] = []
        // Turning steadily left through +180° (raw wraps to -180°) at 50°/s.
        for (i, d) in stride(from: 170.0, through: 200.0, by: 2).enumerated() {
            let raw = d > 180 ? d - 360 : d
            let o = u.process(yawRad: raw * deg, pitchRad: 0, rollRad: 0, rotationRate: (0, 0, 50 * deg),
                              timestamp: Double(i) * 0.04, sensor: 1)
            XCTAssertNil(o.jump)
            outs.append(o.yaw)
        }
        XCTAssertEqual(outs.last ?? 0, 200, accuracy: 1e-6)
        XCTAssertTrue(zip(outs, outs.dropFirst()).allSatisfy { $1 > $0 })
    }

    func testUnexplainedYawStepIsRebased() {
        var u = PoseUnwrapper()
        _ = u.process(yawRad: 12 * deg, pitchRad: 0, rollRad: 0, rotationRate: (0, 0, 0), timestamp: 0, sensor: 1)
        // Spatial Audio starts: yaw snaps to 0 while the gyro saw nothing.
        let o = u.process(yawRad: 0, pitchRad: 0, rollRad: 0, rotationRate: (0, 0, 0), timestamp: 0.04, sensor: 1)
        guard case .unexplainedYawStep(let d)? = o.jump else { return XCTFail("expected a yaw step, got \(String(describing: o.jump))") }
        XCTAssertEqual(d, -12, accuracy: 1e-9)
        XCTAssertEqual(o.yaw, 12, accuracy: 1e-9, "output stays continuous")
        let next = u.process(yawRad: 1 * deg, pitchRad: 0, rollRad: 0, rotationRate: (0, 0, 25 * deg), timestamp: 0.08, sensor: 1)
        XCTAssertEqual(next.yaw, 13, accuracy: 1e-9)
    }

    func testFastRealTurnIsNotAJump() {
        var u = PoseUnwrapper()
        _ = u.process(yawRad: 0, pitchRad: 0, rollRad: 0, rotationRate: (0, 0, 300 * deg), timestamp: 0, sensor: 1)
        // 12° in 40 ms = 300°/s, and the gyro saw it.
        let o = u.process(yawRad: 12 * deg, pitchRad: 0, rollRad: 0, rotationRate: (0, 0, 300 * deg), timestamp: 0.04, sensor: 1)
        XCTAssertNil(o.jump)
        XCTAssertEqual(o.yaw, 12, accuracy: 1e-9)
        XCTAssertEqual(o.speed, 300, accuracy: 1e-9)
    }

    func testSensorSwitchRebasesYawAndPitch() {
        var u = PoseUnwrapper()
        _ = u.process(yawRad: 5 * deg, pitchRad: 2 * deg, rollRad: 0, rotationRate: (0, 0, 0), timestamp: 0, sensor: 1)
        let o = u.process(yawRad: 8 * deg, pitchRad: -1 * deg, rollRad: 0, rotationRate: (0, 0, 0), timestamp: 0.04, sensor: 2)
        guard case .sensorSwitch(let dy, let dp)? = o.jump else { return XCTFail("expected a sensor switch") }
        XCTAssertEqual(dy, 3, accuracy: 1e-9)
        XCTAssertEqual(dp, -3, accuracy: 1e-9)
        XCTAssertEqual(o.yaw, 5, accuracy: 1e-9)
        XCTAssertEqual(o.pitch, 2, accuracy: 1e-9)
    }

    func testMouseModel() {
        var m = MouseHeadModel(centre: CGPoint(x: 1280, y: 720))
        let a = m.angles(for: CGPoint(x: 1680, y: 320))       // 400 pt right, 400 pt up
        XCTAssertEqual(a.yaw, -10, accuracy: 1e-9)
        XCTAssertEqual(a.pitch, 10, accuracy: 1e-9)
        _ = m.sample(mouse: CGPoint(x: 1280, y: 720), at: 0)
        let s = m.sample(mouse: CGPoint(x: 1320, y: 720), at: 0.1)   // 400 pt/s
        XCTAssertEqual(s.speed, 10, accuracy: 1e-9)
    }

    func testImplicitRecenterPolicyIsConservative() {
        let w = TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let neighbour = TrackedWindow(id: 2, frameCG: CGRect(x: 1300, y: 0, width: 1000, height: 800))
        var p = ImplicitRecenterPolicy()
        let gap = CGPoint(x: 1150, y: 400)
        XCTAssertTrue(p.shouldNudge(point: gap, focused: w, windows: [w, neighbour], settledFor: 2, now: 10))
        XCTAssertFalse(p.shouldNudge(point: gap, focused: w, windows: [w, neighbour], settledFor: 1, now: 10), "not settled")
        XCTAssertFalse(p.shouldNudge(point: CGPoint(x: 500, y: 400), focused: w, windows: [w], settledFor: 2, now: 10), "already inside")
        XCTAssertFalse(p.shouldNudge(point: CGPoint(x: 1500, y: 400), focused: w, windows: [w, neighbour], settledFor: 2, now: 10),
                       "reading the neighbour")
        XCTAssertFalse(p.shouldNudge(point: CGPoint(x: 2200, y: 400), focused: w, windows: [w], settledFor: 2, now: 10),
                       "further than one window-width")
        p.noteApplied(degrees: 0.5, now: 10)
        XCTAssertFalse(p.shouldNudge(point: gap, focused: w, windows: [w], settledFor: 2, now: 11), "rate limited")
        for i in 0..<6 { p.noteApplied(degrees: 0.5, now: 20 + Double(i) * 3) }
        XCTAssertFalse(p.shouldNudge(point: gap, focused: w, windows: [w], settledFor: 2, now: 100), "budget spent")
        p.resetBudget()
        XCTAssertTrue(p.shouldNudge(point: gap, focused: w, windows: [w], settledFor: 2, now: 100))
    }
}
