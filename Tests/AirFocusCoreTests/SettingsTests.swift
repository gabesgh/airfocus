import CoreGraphics
import XCTest
@testable import AirFocusCore

final class SensitivityTests: XCTestCase {
    func testMidpointEqualsTodaysValuesExactly() {
        let t = SensitivityTuning(sensitivity: 0.5)
        XCTAssertEqual(t.dwell, 0.45)
        XCTAssertEqual(t.maxSpeedDegPerSec, 25)
        XCTAssertEqual(t.hysteresisMinPoints, 40)
        XCTAssertEqual(t.hysteresisFraction, 0.08)
        XCTAssertEqual(t.cooldown, 0.6)
        XCTAssertEqual(t.filterMinCutoff, 1.0)
        XCTAssertEqual(t.filterBeta, 0.05)
        XCTAssertEqual(t.filterDCutoff, 1.0)
        XCTAssertEqual(t, .balanced)
    }

    func testMidpointMatchesTheSelectorAndFilterDefaults() {
        let plain = TargetSelector.Config()
        var tuned = TargetSelector.Config()
        SensitivityTuning(sensitivity: SettingsDefault.sensitivity).apply(to: &tuned)
        XCTAssertEqual(tuned.dwell, plain.dwell)
        XCTAssertEqual(tuned.maxSpeedDegPerSec, plain.maxSpeedDegPerSec)
        XCTAssertEqual(tuned.hysteresisMinPoints, plain.hysteresisMinPoints)
        XCTAssertEqual(tuned.hysteresisFraction, plain.hysteresisFraction)
        XCTAssertEqual(tuned.cooldown, plain.cooldown)
        let filter = HeadPoseFilter()
        XCTAssertEqual(filter.yaw.minCutoff, SensitivityTuning.balanced.filterMinCutoff)
        XCTAssertEqual(filter.yaw.beta, SensitivityTuning.balanced.filterBeta)
        XCTAssertEqual(filter.yaw.dCutoff, SensitivityTuning.balanced.filterDCutoff)
    }

    func testEndsAreCalmAndSnappy() {
        func assertClose(_ a: SensitivityTuning, _ b: SensitivityTuning) {
            let paths: [KeyPath<SensitivityTuning, Double>] = [\.dwell, \.maxSpeedDegPerSec, \.hysteresisMinPoints, \.hysteresisFraction,
                                                               \.cooldown, \.filterMinCutoff, \.filterBeta, \.filterDCutoff]
            for p in paths { XCTAssertEqual(a[keyPath: p], b[keyPath: p], accuracy: 1e-12) }
        }
        assertClose(SensitivityTuning(sensitivity: 0), .calm)
        assertClose(SensitivityTuning(sensitivity: 1), .snappy)
    }

    func testEveryParameterIsMonotonic() {
        let falling: [KeyPath<SensitivityTuning, Double>] = [\.dwell, \.hysteresisMinPoints, \.hysteresisFraction, \.cooldown]
        let rising: [KeyPath<SensitivityTuning, Double>] = [\.maxSpeedDegPerSec, \.filterMinCutoff, \.filterBeta]
        var last = SensitivityTuning(sensitivity: 0)
        for i in 1...200 {
            let t = SensitivityTuning(sensitivity: Double(i) / 200)
            for p in falling { XCTAssertLessThan(t[keyPath: p], last[keyPath: p], "step \(i)") }
            for p in rising { XCTAssertGreaterThan(t[keyPath: p], last[keyPath: p], "step \(i)") }
            XCTAssertEqual(t.filterDCutoff, 1.0, "dCutoff is not part of the slider")
            last = t
        }
    }

    func testOutOfRangeInputIsClamped() {
        XCTAssertEqual(SensitivityTuning(sensitivity: -3), SensitivityTuning(sensitivity: 0))
        XCTAssertEqual(SensitivityTuning(sensitivity: 42), SensitivityTuning(sensitivity: 1))
        XCTAssertEqual(SensitivityTuning(sensitivity: -.infinity), SensitivityTuning(sensitivity: 0))
        XCTAssertEqual(SensitivityTuning(sensitivity: .infinity), SensitivityTuning(sensitivity: 1))
        XCTAssertEqual(SensitivityTuning(sensitivity: .nan), .balanced)
    }

    func testSliderStopsIncludeTheExactMidpoint() {
        XCTAssertEqual(SensitivityTuning.snapped(0.5), 0.5)
        XCTAssertEqual(SensitivityTuning.snapped(0.5123), 0.5)
        XCTAssertEqual(SensitivityTuning(sensitivity: SensitivityTuning.snapped(0.4876)), .balanced)
        XCTAssertEqual(SensitivityTuning.snapped(2), 1)
        XCTAssertEqual(SensitivityTuning.snapped(-1), 0)
    }

    func testReadout() {
        XCTAssertEqual(SensitivityTuning(sensitivity: 0.5).readout, "switches after 450 ms")
        XCTAssertEqual(SensitivityTuning(sensitivity: 0).readout, "switches after 800 ms")
        XCTAssertEqual(SensitivityTuning(sensitivity: 1).readout, "switches after 250 ms")
    }

    func testTypingGuardAndOtherSafetyValuesAreNotTuned() {
        for s in [0, 0.25, 0.5, 0.75, 1] {
            var c = TargetSelector.Config()
            c.autoSwitch = false
            SensitivityTuning(sensitivity: s).apply(to: &c)
            XCTAssertEqual(c.typingHold, TargetSelector.Config().typingHold)
            XCTAssertEqual(c.offScreenMargin, TargetSelector.Config().offScreenMargin)
            XCTAssertEqual(c.keyboardGlanceDegrees, TargetSelector.Config().keyboardGlanceDegrees)
            XCTAssertEqual(c.gapMaxDegrees, TargetSelector.Config().gapMaxDegrees)
            XCTAssertFalse(c.autoSwitch, "the slider must not turn switching back on")
        }
    }

    func testSelectorSwitchesAtTheTunedDwell() throws {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let a = TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 100, width: 1280, height: 1000))
        let b = TrackedWindow(id: 2, frameCG: CGRect(x: 1280, y: 100, width: 1280, height: 1000))
        for (s, dwell) in [(0.0, 0.8), (0.5, 0.45), (1.0, 0.25)] {
            var selector = TargetSelector()
            SensitivityTuning(sensitivity: s).apply(to: &selector.config)
            var switched: Double?
            var t = 0.0
            while t <= 1.5, switched == nil {
                let input = TargetSelector.Input(point: CGPoint(x: 1900, y: 600), yaw: 0, pitch: 0, speed: 0, now: t, lastKeyDown: -100,
                                                 windows: [a, b], screensCG: [screen], lowestCalibratedPitch: -5)
                if selector.update(input).switchTo == 2 { switched = t }
                t += 0.01
            }
            XCTAssertEqual(try XCTUnwrap(switched), dwell, accuracy: 0.02)
        }
    }

    /// The Settings window holds switching through `autoSwitch`. While held the pointer's window is
    /// still reported, nothing switches, and on release the dwell starts over: closing Settings must
    /// not fire a switch the head "earned" while the user was adjusting a slider.
    func testHoldingSwitchingRestartsTheDwellOnRelease() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let a = TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 100, width: 1280, height: 1000))
        let b = TrackedWindow(id: 2, frameCG: CGRect(x: 1280, y: 100, width: 1280, height: 1000))
        var selector = TargetSelector()
        selector.syncCurrent(1)
        func step(_ t: Double) -> TargetSelector.Decision {
            selector.update(TargetSelector.Input(point: CGPoint(x: 1900, y: 600), yaw: 0, pitch: 0, speed: 0, now: t, lastKeyDown: -100,
                                                 windows: [a, b], screensCG: [screen], lowestCalibratedPitch: -5))
        }
        XCTAssertEqual(step(0).pending, 2)
        selector.config.autoSwitch = false
        for t in stride(from: 0.04, through: 2.0, by: 0.04) {
            let d = step(t)
            XCTAssertNil(d.switchTo)
            XCTAssertNil(d.pending)
            XCTAssertEqual(d.underPointer, 2, "the highlight keeps following the head")
        }
        selector.config.autoSwitch = true
        XCTAssertNil(step(2.04).switchTo, "no instant switch on release")
        XCTAssertNil(step(2.04 + 0.40).switchTo)
        XCTAssertEqual(step(2.04 + 0.46).switchTo, 2, "a full dwell after release")
    }

    func testFilterTuningKeepsItsStateSoThePointerDoesNotJump() {
        var f = HeadPoseFilter()
        _ = f.filter(yaw: 10, pitch: 5, at: 0)
        let before = f.filter(yaw: 10, pitch: 5, at: 0.04)
        f.setTuning(minCutoff: 1.6, beta: 0.12, dCutoff: 1.0)
        XCTAssertEqual(f.yaw.minCutoff, 1.6)
        XCTAssertEqual(f.pitch.beta, 0.12)
        let after = f.filter(yaw: 10, pitch: 5, at: 0.08)
        XCTAssertEqual(after.yaw, before.yaw, accuracy: 1e-9)
    }
}

final class AppSettingsTests: XCTestCase {
    private let suite = "com.gshimoon.airfocus.tests"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    /// Leaves nothing behind: removing a domain still leaves an empty plist in ~/Library/Preferences.
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: file)
    }

    private var stored: [String: Any] { defaults.persistentDomain(forName: suite) ?? [:] }

    // MARK: Defaults

    func testDefaultsMatchTodaysLook() {
        let s = AppSettings(defaults: defaults)
        let a = s.overlayAppearance
        XCTAssertEqual(a, OverlayAppearance())
        XCTAssertTrue(a.showDots)
        XCTAssertEqual(a.dotColor, .white)
        XCTAssertEqual(a.dotSize, 14)
        XCTAssertTrue(a.showBorder)
        XCTAssertTrue(a.borderColor.followsAccent)
        XCTAssertEqual(a.borderWidth, 4)
        XCTAssertEqual(a.pendingBorderWidth, 2.5)
        XCTAssertTrue(a.showPointer)
        XCTAssertTrue(a.pointerColor.followsAccent)
        XCTAssertTrue(a.showRing)
        XCTAssertEqual(a.ringRadius, 13)
        XCTAssertTrue(a.showBanners)
    }

    func testDefaultsMatchTodaysBehaviour() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.sensitivity, 0.5)
        XCTAssertEqual(s.tuning, .balanced)
        XCTAssertEqual(s.focusMode, .automatic)
        XCTAssertTrue(s.lookAwayEnabled)
        XCTAssertEqual(s.lookAwayDelay, 5)
        XCTAssertFalse(s.lockImmediately)
        XCTAssertFalse(s.treatRemovalAsAway)
    }

    func testCreatingSettingsWritesNothing() {
        let s = AppSettings(defaults: defaults)
        _ = s.overlayAppearance
        _ = s.tuning
        XCTAssertTrue(stored.isEmpty, "the CLI reads settings from the app's own domain: \(stored.keys)")
    }

    func testLookAwayDelayChoices() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(SettingsDefault.lookAwayDelayChoices, [5, 10, 20, 30, 60])
        s.lookAwayDelay = 60
        XCTAssertEqual(s.lookAwayDelay, 60)
        s.lookAwayDelay = 7
        XCTAssertEqual(s.lookAwayDelay, 5)
    }

    // MARK: Migration

    func testSwitchSpeedMigratesToTheSensitivityWithTheSameDwell() {
        for speed in SwitchSpeed.allCases {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(speed.rawValue, forKey: SettingsKey.switchSpeed)
            let s = AppSettings(defaults: defaults)
            s.migrateLegacySettings()
            XCTAssertEqual(s.tuning.dwell, speed.dwell, accuracy: 1e-9, speed.rawValue)
            XCTAssertNil(defaults.object(forKey: SettingsKey.switchSpeed), "old key removed")
        }
    }

    func testNormalSwitchSpeedMigratesToExactlyTheMidpoint() {
        defaults.set("normal", forKey: SettingsKey.switchSpeed)
        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        XCTAssertEqual(s.sensitivity, 0.5)
        XCTAssertEqual(s.tuning, .balanced)
    }

    func testMigrationRunsOnlyOnce() {
        defaults.set("fast", forKey: SettingsKey.switchSpeed)
        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        s.sensitivity = 0.1                 // the user moves the slider afterwards
        s.migrateLegacySettings()
        XCTAssertEqual(s.sensitivity, 0.1)
    }

    func testStoredSensitivityWinsOverAStaleSwitchSpeed() {
        defaults.set(0.2, forKey: SettingsKey.sensitivity)
        defaults.set("fast", forKey: SettingsKey.switchSpeed)
        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        XCTAssertEqual(s.sensitivity, 0.2)
        XCTAssertNil(defaults.object(forKey: SettingsKey.switchSpeed))
    }

    func testCorruptSwitchSpeedMigratesToTheDefault() {
        for junk: Any in ["warp", 7, Data([1, 2])] {
            defaults.set(junk, forKey: SettingsKey.switchSpeed)
            let s = AppSettings(defaults: defaults)
            s.migrateLegacySettings()
            XCTAssertEqual(s.sensitivity, 0.5)
            XCTAssertNil(defaults.object(forKey: SettingsKey.switchSpeed))
            XCTAssertNil(defaults.object(forKey: SettingsKey.sensitivity))
        }
    }

    func testMigrationWithNothingStoredWritesNothing() {
        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: Colours

    func testColourRoundTrip() {
        let colours: [StyleColor] = [.accent, .white, StyleColor(red: 0, green: 0, blue: 0),
                                     StyleColor(red: 0.123456789012345, green: 2.0 / 3.0, blue: 0.1 + 0.2, alpha: 0.5)]
        for c in colours { XCTAssertEqual(StyleColor(storageString: c.storageString), c, c.storageString) }
        let s = AppSettings(defaults: defaults)
        s.dotColor = colours[3]
        s.borderColor = .white
        s.pointerColor = .accent
        XCTAssertEqual(s.dotColor, colours[3])
        XCTAssertEqual(s.borderColor, .white)
        XCTAssertTrue(s.pointerColor.followsAccent)
    }

    func testCorruptColourStringsAreRejected() {
        for bad in ["", " ", "accent2", "ACCENT", "#FFFFFF", "1 1 1", "1 1 1 1 1", "a b c d", "nan 0 0 1", "inf 0 0 1",
                    "1.5 0 0 1", "-0.1 0 0 1", "0 0 0 0", "1 1 1 0.1", "0 0 0 2"] {
            XCTAssertNil(StyleColor(storageString: bad), "accepted \(bad)")
        }
    }

    func testColourInitNeverProducesAnOutOfRangeOrInvisibleColour() {
        let wide = StyleColor(red: 1.2, green: -0.3, blue: .nan, alpha: 0)
        XCTAssertEqual(wide.red, 1)
        XCTAssertEqual(wide.green, 0)
        XCTAssertEqual(wide.blue, 0)
        XCTAssertEqual(wide.alpha, StyleColor.minimumAlpha)
        XCTAssertNotNil(StyleColor(storageString: wide.storageString), "whatever init makes must survive storage")
    }

    func testCorruptStoredColoursFallBackToTheirDefaults() {
        let s = AppSettings(defaults: defaults)
        for junk: Any in ["garbage", "0 0 0 0", 12, true, Data([0, 1]), ["r": 1]] {
            for key in [SettingsKey.dotColor, SettingsKey.borderColor, SettingsKey.pointerColor] { defaults.set(junk, forKey: key) }
            XCTAssertEqual(s.dotColor, SettingsDefault.dotColor)
            XCTAssertEqual(s.borderColor, SettingsDefault.borderColor)
            XCTAssertEqual(s.pointerColor, SettingsDefault.pointerColor)
        }
    }

    func testCorruptOrOutOfRangeNumbersFallBackToTheirDefaults() {
        let s = AppSettings(defaults: defaults)
        for junk: Any in ["abc", "0.7", true, Data([1]), Double.nan, Double.infinity] {
            defaults.set(junk, forKey: SettingsKey.sensitivity)
            XCTAssertEqual(s.sensitivity, 0.5, "\(junk)")   // `double(forKey:)` would read "abc" as 0, i.e. Calm
            defaults.set(junk, forKey: SettingsKey.dotSize)
            XCTAssertEqual(s.dotSize, 14, "\(junk)")
            defaults.set(junk, forKey: SettingsKey.borderWidth)
            XCTAssertEqual(s.borderWidth, 4, "\(junk)")
        }
        for (key, bad, get) in [(SettingsKey.sensitivity, 1.01, { s.sensitivity }), (SettingsKey.sensitivity, -0.01, { s.sensitivity }),
                                (SettingsKey.dotSize, 0, { s.dotSize }), (SettingsKey.dotSize, 500, { s.dotSize }),
                                (SettingsKey.borderWidth, 0, { s.borderWidth }), (SettingsKey.borderWidth, 80, { s.borderWidth })] as [(String, Double, () -> Double)] {
            defaults.removeObject(forKey: key)
            let want = get()
            defaults.set(bad, forKey: key)
            XCTAssertEqual(get(), want, "\(key) = \(bad)")
        }
    }

    func testHexParsing() {
        let c = StyleColor(hexOrAccent: "#FF8000")
        XCTAssertEqual(c?.red, 1)
        XCTAssertEqual(c?.green ?? 0, 128.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(c?.blue, 0)
        XCTAssertEqual(StyleColor(hexOrAccent: "accent"), .accent)
        for bad in ["", "#FFF", "#GGGGGG", "FF80001", "red"] { XCTAssertNil(StyleColor(hexOrAccent: bad), bad) }
    }

    func testDarkFillsGetALightRimAndLightFillsKeepTheDarkOne() {
        XCTAssertFalse(StyleColor.needsLightRim(red: 1, green: 1, blue: 1), "today's white dot keeps its dark rim")
        XCTAssertFalse(StyleColor.needsLightRim(red: 1, green: 0.8, blue: 0))
        XCTAssertTrue(StyleColor.needsLightRim(red: 0, green: 0, blue: 0))
        XCTAssertTrue(StyleColor.needsLightRim(red: 0.05, green: 0.05, blue: 0.3))
    }

    // MARK: Restore Defaults

    func testRestoreDefaultsResetsAppearanceAndSensitivityOnly() {
        let s = AppSettings(defaults: defaults)
        s.sensitivity = 0.9
        s.showWindowDots = false
        s.dotColor = StyleColor(red: 1, green: 0, blue: 0)
        s.dotSize = 20
        s.showFocusBorder = false
        s.borderColor = .white
        s.borderWidth = 8
        s.showHeadPointer = false
        s.pointerColor = .white
        s.showProgressRing = false
        s.showStatusBanners = false
        s.focusMode = .hotkeyOnly
        s.lookAwayDelay = 30
        s.lookAwayEnabled = false
        s.lockImmediately = true
        s.treatRemovalAsAway = true

        s.restoreAppearanceAndSensitivity()

        XCTAssertEqual(s.overlayAppearance, OverlayAppearance())
        XCTAssertEqual(s.sensitivity, 0.5)
        XCTAssertEqual(s.focusMode, .hotkeyOnly)
        XCTAssertEqual(s.lookAwayDelay, 30)
        XCTAssertFalse(s.lookAwayEnabled)
        XCTAssertTrue(s.lockImmediately)
        XCTAssertTrue(s.treatRemovalAsAway)
    }

    // MARK: Overlay mode and session traces

    func testOverlayIsHiddenByDefault() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.overlayMode, .hidden)
        XCTAssertFalse(s.recordSessionTrace, "traces are opt in")
        XCTAssertTrue(stored.isEmpty, "the defaults are registered, not written")
    }

    /// An install from before the setting existed has other keys stored but not this one: Hidden too.
    func testAnExistingInstallGetsHiddenToo() {
        defaults.set(true, forKey: SettingsKey.trackingWasOn)
        defaults.set(StyleColor.white.storageString, forKey: SettingsKey.dotColor)
        defaults.set(0.65, forKey: SettingsKey.sensitivity)
        defaults.set(false, forKey: SettingsKey.showWindowDots)
        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        XCTAssertEqual(s.overlayMode, .hidden)
        XCTAssertFalse(s.overlayAppearance.showDots, "the stored look is kept for Visible")
    }

    func testOverlayModeRoundTripsAndFallsBackToHidden() {
        let s = AppSettings(defaults: defaults)
        s.overlayMode = .visible
        XCTAssertEqual(s.overlayMode, .visible)
        XCTAssertEqual(stored[SettingsKey.overlayMode] as? String, "visible")
        for junk: Any in ["shown", 1, true, Data([1])] {
            defaults.set(junk, forKey: SettingsKey.overlayMode)
            XCTAssertEqual(s.overlayMode, .hidden, "\(junk)")
        }
    }

    func testRestoreDefaultsKeepsTheOverlayModeAndTraceRecording() {
        let s = AppSettings(defaults: defaults)
        s.overlayMode = .visible
        s.recordSessionTrace = false
        s.dotSize = 20
        s.restoreAppearanceAndSensitivity()
        XCTAssertEqual(s.overlayMode, .visible)
        XCTAssertFalse(s.recordSessionTrace)
        XCTAssertEqual(s.dotSize, 14)
    }

    // MARK: Calibrations

    func testCalibrationsKeySurvivesEverything() throws {
        let blob: [String: Data] = ["display-a": Data([1, 2, 3]), "sim:display-a": Data([4])]
        defaults.set(blob, forKey: SettingsKey.calibrations)
        defaults.set("slow", forKey: SettingsKey.switchSpeed)

        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        s.sensitivity = 0.7
        s.dotColor = .white
        s.restoreAppearanceAndSensitivity()
        s.migrateLegacySettings()

        XCTAssertEqual(defaults.dictionary(forKey: SettingsKey.calibrations) as? [String: Data], blob)
    }

    func testCalibrationStoreStillReadsThroughSettingsChanges() throws {
        let samples = [CalibrationSample(yaw: 10, pitch: 5, screen: CGPoint(x: 100, y: 100)),
                       CalibrationSample(yaw: -10, pitch: 5, screen: CGPoint(x: 1500, y: 100)),
                       CalibrationSample(yaw: 10, pitch: -5, screen: CGPoint(x: 100, y: 900)),
                       CalibrationSample(yaw: -10, pitch: -5, screen: CGPoint(x: 1500, y: 900))]
        let cal = try XCTUnwrap(HeadCalibration.fit(samples: samples, anchors: [], displayKey: "display-a"))
        let store = CalibrationStore(defaults: defaults)
        store.save(cal)
        let s = AppSettings(defaults: defaults)
        s.migrateLegacySettings()
        s.restoreAppearanceAndSensitivity()
        XCTAssertEqual(store.load(displayKey: "display-a")?.samples.count, 4)
    }
}

final class PointerStyleTests: XCTestCase {
    private func settings() throws -> (AppSettings, UserDefaults, String) {
        let suite = "AirFocusTests.\(UUID().uuidString)"
        return (AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testDefaultsAreTheOriginalPointer() throws {
        let (s, d, suite) = try settings()
        defer { d.removePersistentDomain(forName: suite) }
        let a = s.overlayAppearance
        XCTAssertEqual(a.pointerShape, .circle)
        XCTAssertEqual(a.pointerSize, 26)
        XCTAssertEqual(a.pointerLineWidth, 2.5)
    }

    func testShapeAndSizeRoundTripAndRestore() throws {
        let (s, d, suite) = try settings()
        defer { d.removePersistentDomain(forName: suite) }
        for shape in PointerShape.allCases {
            s.pointerShape = shape
            XCTAssertEqual(s.overlayAppearance.pointerShape, shape)
        }
        s.pointerSize = 12
        XCTAssertEqual(s.overlayAppearance.pointerSize, 12)
        s.restoreAppearanceAndSensitivity()
        XCTAssertEqual(s.pointerShape, .circle)
        XCTAssertEqual(s.pointerSize, 26)
    }

    func testBadValuesFallBack() throws {
        let (s, d, suite) = try settings()
        defer { d.removePersistentDomain(forName: suite) }
        d.set("hexagon", forKey: SettingsKey.pointerShape)
        XCTAssertEqual(s.pointerShape, .circle)
        for junk in [0.0, 2.0, 500.0, -.infinity, .nan] {
            d.set(junk, forKey: SettingsKey.pointerSize)
            XCTAssertEqual(s.pointerSize, 26, "\(junk)")
        }
    }

    func testLineWidthStaysVisibleAtEverySize() {
        var a = OverlayAppearance()
        for size in stride(from: SettingsDefault.pointerSizeRange.lowerBound, through: SettingsDefault.pointerSizeRange.upperBound, by: 1) {
            a.pointerSize = size
            XCTAssertTrue((1.5...2.5).contains(a.pointerLineWidth), "\(size)")
        }
    }
}

final class MenuBarIconModeTests: XCTestCase {
    func testDefaultRoundTripAndFallback() throws {
        let suite = "AirFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.menuBarIcon, .always, "upgrading changes nothing")
        XCTAssertFalse(s.autoHideExplained)
        for mode in MenuBarIconMode.allCases {
            s.menuBarIcon = mode
            XCTAssertEqual(s.menuBarIcon, mode)
        }
        defaults.set("sometimes", forKey: SettingsKey.menuBarIcon)
        XCTAssertEqual(s.menuBarIcon, .always)
        s.menuBarIcon = .hidden
        s.restoreAppearanceAndSensitivity()
        XCTAssertEqual(s.menuBarIcon, .hidden, "Restore Defaults is for styling, not this")
    }
}
