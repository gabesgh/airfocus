import Foundation

/// Capture state machine for one calibration point (R§8.3, spec §2.3):
/// travel to the dot → settle (gyro < 10°/s for 300 ms) → average 500 ms → reject and retry if the
/// std dev > 1° → done.
public struct CalibrationCapture: Sendable {
    public struct Config: Sendable {
        public var minTravel = 2.0                    // degrees from where the head was when the dot appeared
        public var travelGrace: TimeInterval = 2.5    // stop waiting for travel (the dot may be next to the last one)
        public var settleSpeed = 10.0                 // °/s
        public var settleTime: TimeInterval = 0.3
        public var averageTime: TimeInterval = 0.5
        public var maxStdDev = 1.0                    // degrees, per axis
        public var minSamples = 3                     // at ~25 Hz a 500 ms window holds ~12
        public var timeout: TimeInterval = 15         // give up on this point (the caller skips it)
        public var recentWindow: TimeInterval = 0.5   // what Return averages when pressed early

        public init() {}
    }

    public enum Phase: Equatable, Sendable { case idle, settling, averaging, captured, timedOut }

    public struct Measurement: Equatable, Sendable {
        public var yaw: Double
        public var pitch: Double
        public var stdDev: Double
        public var count: Int
    }

    public enum Event: Equatable, Sendable {
        case none
        case rejected(stdDev: Double)
        case captured(Measurement)
        case timedOut
    }

    private struct Sample: Sendable { var t: TimeInterval; var yaw: Double; var pitch: Double }

    public var config: Config
    public private(set) var phase: Phase = .idle
    public private(set) var rejectCount = 0
    public private(set) var result: Measurement?
    private var startedAt: TimeInterval = 0
    private var expectTravel = true
    private var origin: Sample?
    private var ready = false
    private var settleSince: TimeInterval?
    private var averagingSince: TimeInterval = 0
    private var buffer: [Sample] = []
    private var recent: [Sample] = []

    public init(config: Config = Config()) { self.config = config }

    /// `expectTravel: false` for the first point: there is no previous dot to travel from, and the
    /// yaw steps of a starting stream would read as travel, so only the grace period counts.
    public mutating func begin(at now: TimeInterval, expectTravel: Bool = true) {
        phase = .settling
        rejectCount = 0
        result = nil
        startedAt = now
        self.expectTravel = expectTravel
        origin = nil
        ready = false
        settleSince = nil
        buffer.removeAll()
        recent.removeAll()
    }

    public var isFinished: Bool { phase == .captured || phase == .timedOut }

    public mutating func feed(yaw: Double, pitch: Double, speed: Double, now: TimeInterval) -> Event {
        guard phase == .settling || phase == .averaging else { return .none }
        let s = Sample(t: now, yaw: yaw, pitch: pitch)
        recent.append(s)
        recent.removeAll { now - $0.t > config.recentWindow }

        if now - startedAt > config.timeout { phase = .timedOut; return .timedOut }

        switch phase {
        case .settling:
            // A head that is already still is aimed at the previous dot: wait for it to move.
            if !ready {
                let o = origin ?? s
                origin = o
                let traveled = expectTravel && hypot(yaw - o.yaw, pitch - o.pitch) >= config.minTravel
                ready = traveled || now - startedAt >= config.travelGrace
                guard ready else { return .none }
            }
            guard speed < config.settleSpeed else { settleSince = nil; return .none }
            if settleSince == nil { settleSince = now }
            if let since = settleSince, now - since >= config.settleTime {
                phase = .averaging
                averagingSince = now
                buffer = [s]
            }
            return .none
        case .averaging:
            buffer.append(s)
            guard now - averagingSince >= config.averageTime, buffer.count >= config.minSamples else { return .none }
            let m = Self.measure(buffer)
            if m.stdDev > config.maxStdDev {
                rejectCount += 1
                phase = .settling
                settleSince = nil
                buffer.removeAll()
                return .rejected(stdDev: m.stdDev)
            }
            phase = .captured
            result = m
            return .captured(m)
        default:
            return .none
        }
    }

    /// For a timer tick when no samples arrive at all.
    public mutating func checkTimeout(now: TimeInterval) -> Event {
        guard phase == .settling || phase == .averaging, now - startedAt > config.timeout else { return .none }
        phase = .timedOut
        return .timedOut
    }

    /// Return pressed: capture immediately from what we have (the averaging buffer, else the last 500 ms).
    public mutating func captureNow() -> Measurement? {
        guard phase == .settling || phase == .averaging else { return nil }
        let source = (phase == .averaging && !buffer.isEmpty) ? buffer : recent
        guard !source.isEmpty else { return nil }
        let m = Self.measure(source)
        phase = .captured
        result = m
        return m
    }

    /// 0...1 for the capture ring: settle time and averaging time laid end to end.
    public func progress(now: TimeInterval) -> Double {
        let total = config.settleTime + config.averageTime
        switch phase {
        case .idle, .timedOut: return 0
        case .captured: return 1
        case .settling:
            guard let since = settleSince else { return 0 }
            return min(config.settleTime, now - since) / total
        case .averaging:
            return (config.settleTime + min(config.averageTime, now - averagingSince)) / total
        }
    }

    private static func measure(_ s: [Sample]) -> Measurement {
        let n = Double(s.count)
        let my = s.reduce(0) { $0 + $1.yaw } / n
        let mp = s.reduce(0) { $0 + $1.pitch } / n
        let vy = s.reduce(0) { $0 + ($1.yaw - my) * ($1.yaw - my) } / n
        let vp = s.reduce(0) { $0 + ($1.pitch - mp) * ($1.pitch - mp) } / n
        return Measurement(yaw: my, pitch: mp, stdDev: max(vy, vp).squareRoot(), count: s.count)
    }
}
