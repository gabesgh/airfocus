import Foundation

public enum FocusMode: String, CaseIterable, Sendable {
    case automatic      // dwell switches focus on its own
    case hotkeyOnly     // only ⌃⌥⌘F focuses the window under the head pointer
}

/// Whether the runtime overlay draws while tracking (spec §2.2). Hidden draws nothing during normal
/// use; calibration, essential banners, Mission Control's pointer and the ⌃⌥⌘R cue still show.
public enum OverlayMode: String, CaseIterable, Sendable {
    case hidden, visible
}

/// Whether the status item shows (spec §2.1). Hotkeys keep working either way, and opening the app
/// again (Spotlight, Finder) brings up Settings, the way back when the icon is hidden.
public enum MenuBarIconMode: String, CaseIterable, Sendable {
    case always, autoHide, hidden

    public var title: String {
        switch self {
        case .always: return "Always shown"
        case .autoHide: return "Hidden 5 seconds after you leave AirFocus"
        case .hidden: return "Hidden"
        }
    }
}

/// The old menu's Switch Speed, kept only to migrate a stored choice to Sensitivity.
public enum SwitchSpeed: String, CaseIterable, Sendable {
    case fast, normal, slow

    public var dwell: TimeInterval {
        switch self {
        case .fast: return 0.30
        case .normal: return 0.45
        case .slow: return 0.70
        }
    }
}

/// UserDefaults keys. The domain is the app's own (com.gshimoon.airfocus).
public enum SettingsKey {
    public static let focusMode = "focusMode"
    public static let switchSpeed = "switchSpeed"    // legacy: migrated to `sensitivity`, then removed
    public static let sensitivity = "sensitivity"
    public static let showWindowDots = "showWindowDots"
    public static let dotColor = "dotColor"
    public static let dotSize = "dotSize"
    public static let showFocusBorder = "showFocusBorder"
    public static let borderColor = "borderColor"
    public static let borderWidth = "borderWidth"
    public static let showHeadPointer = "showHeadPointer"
    public static let pointerColor = "pointerColor"
    public static let pointerShape = "pointerShape"
    public static let pointerSize = "pointerSize"
    public static let showProgressRing = "showProgressRing"
    public static let showStatusBanners = "showStatusBanners"
    public static let overlayMode = "overlayMode"
    public static let menuBarIcon = "menuBarIcon"
    public static let autoHideExplained = "autoHideExplained"
    public static let recordSessionTrace = "recordSessionTrace"
    public static let flickUpEnabled = "flickUpEnabled"
    public static let flickSidewaysEnabled = "flickSidewaysEnabled"
    public static let flickSensitivity = "flickSensitivity"
    public static let missionControlPick = "missionControlPick"
    public static let lookAwayEnabled = "lookAwayEnabled"
    public static let lookAwayDelay = "lookAwayDelay"
    public static let lockImmediately = "lockImmediately"
    public static let treatRemovalAsAway = "treatRemovalAsAway"
    public static let simulateWithMouse = "simulateWithMouse"
    public static let trackingWasOn = "trackingWasOn"
    public static let stageManagerNoticeShown = "stageManagerNoticeShown"
    public static let calibrations = "calibrations"
}

/// Defaults from the spec (§2.1) and R§11.5.
public enum SettingsDefault {
    public static let focusMode = FocusMode.automatic
    public static let sensitivity = SensitivityTuning.midpoint
    public static let showWindowDots = true
    public static let dotColor = StyleColor.white
    public static let dotSize = 14.0
    public static let dotSizeRange = 8.0...24.0
    public static let showFocusBorder = true
    public static let borderColor = StyleColor.accent
    public static let borderWidth = 4.0
    public static let borderWidthRange = 1.0...10.0
    public static let showHeadPointer = true
    public static let pointerColor = StyleColor.accent
    public static let pointerShape = PointerShape.circle
    public static let pointerSize = 26.0
    public static let pointerSizeRange = 8.0...48.0
    public static let showProgressRing = true
    public static let showStatusBanners = true
    /// Hidden for everyone, existing installs included: nothing stored means Hidden.
    public static let overlayMode = OverlayMode.hidden
    public static let menuBarIcon = MenuBarIconMode.always
    public static let recordSessionTrace = false   // opt in: a developer tool for tuning the intent engine
    public static let flickUpEnabled = true
    public static let flickSidewaysEnabled = true
    public static let flickSensitivity = 0.5
    public static let missionControlPick = true
    public static let lookAwayEnabled = true
    public static let lookAwayDelay: TimeInterval = 5
    public static let lookAwayDelayChoices: [TimeInterval] = [5, 10, 20, 30, 60]
    public static let lockImmediately = false
    public static let treatRemovalAsAway = false
}

/// Typed access to the app's preferences. Foundation only, so it is testable with a scratch suite.
/// Creating one writes nothing (register(defaults:) is volatile), so the CLI can read settings
/// without touching the app's domain. Only migrateLegacySettings() and the setters write.
public final class AppSettings {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The validated values (colours, sizes, sensitivity) fall back in their getters instead:
        // migration has to be able to tell a stored `sensitivity` from no value at all.
        defaults.register(defaults: [
            SettingsKey.focusMode: SettingsDefault.focusMode.rawValue,
            SettingsKey.showWindowDots: SettingsDefault.showWindowDots,
            SettingsKey.showFocusBorder: SettingsDefault.showFocusBorder,
            SettingsKey.showHeadPointer: SettingsDefault.showHeadPointer,
            SettingsKey.showProgressRing: SettingsDefault.showProgressRing,
            SettingsKey.showStatusBanners: SettingsDefault.showStatusBanners,
            SettingsKey.overlayMode: SettingsDefault.overlayMode.rawValue,
            SettingsKey.menuBarIcon: SettingsDefault.menuBarIcon.rawValue,
            SettingsKey.autoHideExplained: false,
            SettingsKey.recordSessionTrace: SettingsDefault.recordSessionTrace,
            SettingsKey.flickUpEnabled: SettingsDefault.flickUpEnabled,
            SettingsKey.flickSidewaysEnabled: SettingsDefault.flickSidewaysEnabled,
            SettingsKey.missionControlPick: SettingsDefault.missionControlPick,
            SettingsKey.lookAwayEnabled: SettingsDefault.lookAwayEnabled,
            SettingsKey.lookAwayDelay: SettingsDefault.lookAwayDelay,
            SettingsKey.lockImmediately: SettingsDefault.lockImmediately,
            SettingsKey.treatRemovalAsAway: SettingsDefault.treatRemovalAsAway,
            SettingsKey.simulateWithMouse: false,
            SettingsKey.trackingWasOn: false,
            SettingsKey.stageManagerNoticeShown: false,
        ])
    }

    public var focusMode: FocusMode {
        get { FocusMode(rawValue: defaults.string(forKey: SettingsKey.focusMode) ?? "") ?? SettingsDefault.focusMode }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.focusMode) }
    }

    public var sensitivity: Double {
        get { validNumber(SettingsKey.sensitivity, in: 0...1) ?? SettingsDefault.sensitivity }
        set { defaults.set(SensitivityTuning.clamped(newValue), forKey: SettingsKey.sensitivity) }
    }

    public var tuning: SensitivityTuning { SensitivityTuning(sensitivity: sensitivity) }

    public var showWindowDots: Bool {
        get { defaults.bool(forKey: SettingsKey.showWindowDots) }
        set { defaults.set(newValue, forKey: SettingsKey.showWindowDots) }
    }

    public var dotColor: StyleColor {
        get { validColor(SettingsKey.dotColor) ?? SettingsDefault.dotColor }
        set { defaults.set(newValue.storageString, forKey: SettingsKey.dotColor) }
    }

    public var dotSize: Double {
        get { validNumber(SettingsKey.dotSize, in: SettingsDefault.dotSizeRange) ?? SettingsDefault.dotSize }
        set { defaults.set(newValue, forKey: SettingsKey.dotSize) }
    }

    public var showFocusBorder: Bool {
        get { defaults.bool(forKey: SettingsKey.showFocusBorder) }
        set { defaults.set(newValue, forKey: SettingsKey.showFocusBorder) }
    }

    public var borderColor: StyleColor {
        get { validColor(SettingsKey.borderColor) ?? SettingsDefault.borderColor }
        set { defaults.set(newValue.storageString, forKey: SettingsKey.borderColor) }
    }

    public var borderWidth: Double {
        get { validNumber(SettingsKey.borderWidth, in: SettingsDefault.borderWidthRange) ?? SettingsDefault.borderWidth }
        set { defaults.set(newValue, forKey: SettingsKey.borderWidth) }
    }

    public var showHeadPointer: Bool {
        get { defaults.bool(forKey: SettingsKey.showHeadPointer) }
        set { defaults.set(newValue, forKey: SettingsKey.showHeadPointer) }
    }

    public var pointerColor: StyleColor {
        get { validColor(SettingsKey.pointerColor) ?? SettingsDefault.pointerColor }
        set { defaults.set(newValue.storageString, forKey: SettingsKey.pointerColor) }
    }

    public var pointerShape: PointerShape {
        get { PointerShape(rawValue: defaults.string(forKey: SettingsKey.pointerShape) ?? "") ?? SettingsDefault.pointerShape }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.pointerShape) }
    }

    public var pointerSize: Double {
        get { validNumber(SettingsKey.pointerSize, in: SettingsDefault.pointerSizeRange) ?? SettingsDefault.pointerSize }
        set { defaults.set(newValue, forKey: SettingsKey.pointerSize) }
    }

    public var showProgressRing: Bool {
        get { defaults.bool(forKey: SettingsKey.showProgressRing) }
        set { defaults.set(newValue, forKey: SettingsKey.showProgressRing) }
    }

    public var showStatusBanners: Bool {
        get { defaults.bool(forKey: SettingsKey.showStatusBanners) }
        set { defaults.set(newValue, forKey: SettingsKey.showStatusBanners) }
    }

    public var overlayMode: OverlayMode {
        get { OverlayMode(rawValue: defaults.string(forKey: SettingsKey.overlayMode) ?? "") ?? SettingsDefault.overlayMode }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.overlayMode) }
    }

    public var recordSessionTrace: Bool {
        get { defaults.bool(forKey: SettingsKey.recordSessionTrace) }
        set { defaults.set(newValue, forKey: SettingsKey.recordSessionTrace) }
    }

    /// Everything the runtime overlay needs, validated. How it looks, not whether it draws: that's
    /// `overlayMode`.
    public var overlayAppearance: OverlayAppearance {
        var a = OverlayAppearance()
        a.showDots = showWindowDots
        a.dotColor = dotColor
        a.dotSize = dotSize
        a.showBorder = showFocusBorder
        a.borderColor = borderColor
        a.borderWidth = borderWidth
        a.showPointer = showHeadPointer
        a.pointerColor = pointerColor
        a.pointerShape = pointerShape
        a.pointerSize = pointerSize
        a.showRing = showProgressRing
        a.showBanners = showStatusBanners
        return a
    }

    public var flickUpEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.flickUpEnabled) }
        set { defaults.set(newValue, forKey: SettingsKey.flickUpEnabled) }
    }

    public var flickSidewaysEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.flickSidewaysEnabled) }
        set { defaults.set(newValue, forKey: SettingsKey.flickSidewaysEnabled) }
    }

    public var missionControlPick: Bool {
        get { defaults.bool(forKey: SettingsKey.missionControlPick) }
        set { defaults.set(newValue, forKey: SettingsKey.missionControlPick) }
    }

    public var flickSensitivity: Double {
        get { validNumber(SettingsKey.flickSensitivity, in: 0...1) ?? SettingsDefault.flickSensitivity }
        set { defaults.set(min(1, max(0, newValue)), forKey: SettingsKey.flickSensitivity) }
    }

    public var lookAwayEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.lookAwayEnabled) }
        set { defaults.set(newValue, forKey: SettingsKey.lookAwayEnabled) }
    }

    public var lookAwayDelay: TimeInterval {
        get {
            let v = defaults.double(forKey: SettingsKey.lookAwayDelay)
            return SettingsDefault.lookAwayDelayChoices.contains(v) ? v : SettingsDefault.lookAwayDelay
        }
        set { defaults.set(newValue, forKey: SettingsKey.lookAwayDelay) }
    }

    public var lockImmediately: Bool {
        get { defaults.bool(forKey: SettingsKey.lockImmediately) }
        set { defaults.set(newValue, forKey: SettingsKey.lockImmediately) }
    }

    public var treatRemovalAsAway: Bool {
        get { defaults.bool(forKey: SettingsKey.treatRemovalAsAway) }
        set { defaults.set(newValue, forKey: SettingsKey.treatRemovalAsAway) }
    }

    public var simulateWithMouse: Bool {
        get { defaults.bool(forKey: SettingsKey.simulateWithMouse) }
        set { defaults.set(newValue, forKey: SettingsKey.simulateWithMouse) }
    }

    public var trackingWasOn: Bool {
        get { defaults.bool(forKey: SettingsKey.trackingWasOn) }
        set { defaults.set(newValue, forKey: SettingsKey.trackingWasOn) }
    }

    public var menuBarIcon: MenuBarIconMode {
        get { MenuBarIconMode(rawValue: defaults.string(forKey: SettingsKey.menuBarIcon) ?? "") ?? SettingsDefault.menuBarIcon }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.menuBarIcon) }
    }

    /// The one-time note on how to get the icon back has been shown.
    public var autoHideExplained: Bool {
        get { defaults.bool(forKey: SettingsKey.autoHideExplained) }
        set { defaults.set(newValue, forKey: SettingsKey.autoHideExplained) }
    }

    public var stageManagerNoticeShown: Bool {
        get { defaults.bool(forKey: SettingsKey.stageManagerNoticeShown) }
        set { defaults.set(newValue, forKey: SettingsKey.stageManagerNoticeShown) }
    }

    /// Settings › Restore Defaults: appearance and sensitivity only. Focus mode, overlay mode,
    /// look-away, trace recording and the stored calibrations are left alone.
    public func restoreAppearanceAndSensitivity() {
        for key in [SettingsKey.sensitivity, SettingsKey.showWindowDots, SettingsKey.dotColor, SettingsKey.dotSize,
                    SettingsKey.showFocusBorder, SettingsKey.borderColor, SettingsKey.borderWidth,
                    SettingsKey.showHeadPointer, SettingsKey.pointerColor, SettingsKey.pointerShape, SettingsKey.pointerSize, SettingsKey.showProgressRing,
                    SettingsKey.showStatusBanners, SettingsKey.flickUpEnabled, SettingsKey.flickSidewaysEnabled,
                    SettingsKey.flickSensitivity, SettingsKey.missionControlPick] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Once, at app launch: a stored Switch Speed becomes the sensitivity with the same dwell. A
    /// stored sensitivity wins, and the old key is removed either way so this never runs twice.
    public func migrateLegacySettings() {
        guard let stored = defaults.object(forKey: SettingsKey.switchSpeed) else { return }
        if defaults.object(forKey: SettingsKey.sensitivity) == nil,
           let speed = (stored as? String).flatMap(SwitchSpeed.init(rawValue:)) {
            sensitivity = SensitivityTuning.sensitivity(forDwell: speed.dwell)
        }
        defaults.removeObject(forKey: SettingsKey.switchSpeed)
    }

    // MARK: Validation

    /// `double(forKey:)` turns garbage into 0, a legal sensitivity, so read the object itself.
    private func validNumber(_ key: String, in range: ClosedRange<Double>) -> Double? {
        guard let n = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite && range.contains(v) ? v : nil
    }

    private func validColor(_ key: String) -> StyleColor? {
        (defaults.object(forKey: key) as? String).flatMap(StyleColor.init(storageString:))
    }
}
