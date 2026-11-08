import Foundation

/// What the one Sensitivity slider tunes. Pure, so the mapping is testable: 0 is Calm, 1 is Snappy
/// and 0.5 is exactly the values the selector and filter have always used (spec §2.4, R§8.4).
/// Piecewise linear through those three points. The typing guard and look-away are not in here on
/// purpose: they protect against wrong switches and false screen savers at any sensitivity.
public struct SensitivityTuning: Equatable, Sendable {
    public var dwell: TimeInterval               // candidate must win continuously
    public var maxSpeedDegPerSec: Double         // settled-head gate
    public var hysteresisMinPoints: Double       // current window's hit area grows by
    public var hysteresisFraction: Double        //   max(points, fraction of its size)
    public var cooldown: TimeInterval
    public var filterMinCutoff: Double           // 1€ filter: higher = less smoothing at rest
    public var filterBeta: Double                //   higher = less lag on fast turns
    public var filterDCutoff: Double

    public static let midpoint = 0.5
    /// The slider snaps to this step, so the midpoint can be reached exactly.
    public static let step = 0.05

    public static let calm = SensitivityTuning(
        dwell: 0.8, maxSpeedDegPerSec: 18, hysteresisMinPoints: 70, hysteresisFraction: 0.14, cooldown: 0.9,
        filterMinCutoff: 0.7, filterBeta: 0.03, filterDCutoff: 1.0)
    public static let balanced = SensitivityTuning(
        dwell: 0.45, maxSpeedDegPerSec: 25, hysteresisMinPoints: 40, hysteresisFraction: 0.08, cooldown: 0.6,
        filterMinCutoff: 1.0, filterBeta: 0.05, filterDCutoff: 1.0)
    public static let snappy = SensitivityTuning(
        dwell: 0.25, maxSpeedDegPerSec: 40, hysteresisMinPoints: 20, hysteresisFraction: 0.04, cooldown: 0.35,
        filterMinCutoff: 1.6, filterBeta: 0.12, filterDCutoff: 1.0)

    public init(dwell: TimeInterval, maxSpeedDegPerSec: Double, hysteresisMinPoints: Double,
                hysteresisFraction: Double, cooldown: TimeInterval, filterMinCutoff: Double,
                filterBeta: Double, filterDCutoff: Double) {
        self.dwell = dwell; self.maxSpeedDegPerSec = maxSpeedDegPerSec
        self.hysteresisMinPoints = hysteresisMinPoints; self.hysteresisFraction = hysteresisFraction
        self.cooldown = cooldown; self.filterMinCutoff = filterMinCutoff
        self.filterBeta = filterBeta; self.filterDCutoff = filterDCutoff
    }

    /// Out-of-range input is clamped; NaN means the midpoint.
    public static func clamped(_ sensitivity: Double) -> Double {
        sensitivity.isNaN ? midpoint : min(1, max(0, sensitivity))
    }

    /// Nearest slider stop. Dividing by the inverse keeps 0.5 exact.
    public static func snapped(_ sensitivity: Double) -> Double {
        (clamped(sensitivity) / step).rounded() / (1 / step)
    }

    public init(sensitivity: Double) {
        let s = Self.clamped(sensitivity)
        // Interpolating outwards from the midpoint gives exactly `balanced` at 0.5.
        let end = s < Self.midpoint ? Self.calm : Self.snappy
        let t = abs(s - Self.midpoint) / Self.midpoint
        func mix(_ path: KeyPath<SensitivityTuning, Double>) -> Double {
            let mid = Self.balanced[keyPath: path]
            return mid + (end[keyPath: path] - mid) * t
        }
        self.init(dwell: mix(\.dwell), maxSpeedDegPerSec: mix(\.maxSpeedDegPerSec),
                  hysteresisMinPoints: mix(\.hysteresisMinPoints), hysteresisFraction: mix(\.hysteresisFraction),
                  cooldown: mix(\.cooldown), filterMinCutoff: mix(\.filterMinCutoff),
                  filterBeta: mix(\.filterBeta), filterDCutoff: mix(\.filterDCutoff))
    }

    /// The sensitivity whose dwell is `dwell`, for migrating the old Switch Speed choices.
    public static func sensitivity(forDwell dwell: TimeInterval) -> Double {
        let mid = balanced.dwell
        let s = dwell <= mid ? midpoint + midpoint * (mid - dwell) / (mid - snappy.dwell)
                             : midpoint - midpoint * (dwell - mid) / (calm.dwell - mid)
        return clamped(s)
    }

    public func apply(to config: inout TargetSelector.Config) {
        config.dwell = dwell
        config.maxSpeedDegPerSec = maxSpeedDegPerSec
        config.hysteresisMinPoints = CGFloat(hysteresisMinPoints)
        config.hysteresisFraction = CGFloat(hysteresisFraction)
        config.cooldown = cooldown
    }

    /// The slider's readout, to the nearest 10 ms.
    public var readout: String { "switches after \(Int((dwell * 100).rounded()) * 10) ms" }
}
