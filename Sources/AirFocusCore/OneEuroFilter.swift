import Foundation

/// The 1€ filter (Casiez et al., CHI 2012), R§8.4. Values in degrees, time in seconds.
/// Defaults for this signal: minCutoff 1.0 Hz, beta 0.05 per °/s, dCutoff 1.0 Hz.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    /// A gap longer than this restarts the filter instead of smearing across it.
    public var maxGap: Double = 1.0

    private var x: Double?
    private var dx = 0.0
    private var t: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.05, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func reset() { x = nil; t = nil; dx = 0 }

    public var value: Double? { x }

    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let px = x, let pt = t, time > pt, time - pt <= maxGap else {
            x = value; t = time; dx = 0
            return value
        }
        let dt = max(time - pt, 1e-3)
        dx += Self.alpha(dCutoff, dt) * ((value - px) / dt - dx)
        let out = px + Self.alpha(minCutoff + beta * abs(dx), dt) * (value - px)
        x = out; t = time
        return out
    }
}

/// Yaw and pitch filtered independently with the same parameters.
public struct HeadPoseFilter: Sendable {
    public var yaw: OneEuroFilter
    public var pitch: OneEuroFilter

    public init(minCutoff: Double = 1.0, beta: Double = 0.05, dCutoff: Double = 1.0) {
        yaw = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        pitch = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }

    public mutating func reset() { yaw.reset(); pitch.reset() }

    /// Change the parameters live, keeping the filter state so the pointer doesn't jump.
    public mutating func setTuning(minCutoff: Double, beta: Double, dCutoff: Double) {
        yaw.minCutoff = minCutoff; yaw.beta = beta; yaw.dCutoff = dCutoff
        pitch.minCutoff = minCutoff; pitch.beta = beta; pitch.dCutoff = dCutoff
    }

    public mutating func filter(yaw y: Double, pitch p: Double, at time: Double) -> (yaw: Double, pitch: Double) {
        (yaw.filter(y, at: time), pitch.filter(p, at: time))
    }
}
