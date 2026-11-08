import CoreGraphics
import Foundation

/// Session traces (spec §2.10): a compact, versioned, line-based record of real use, for the intent
/// engine to learn from and for `--replay-trace` to evaluate on. One event per line, a one-letter
/// code, the host time, then fields separated by single spaces. Never a key's identity, a window
/// title or any app content: key-down times, click positions, window ids, pids, bundle ids and frames.
public enum TraceFormat {
    public static let name = "airfocus-trace"
    public static let version = 1
    public static let fileExtension = "aftrace"
    /// The first line of every file, for a person opening one.
    public static let banner = "# AirFocus session trace v\(version): one event per line, see README › Session traces"
}

/// Fixed-point numbers. A traced value is rounded to its field's decimals once, when the event is
/// made, so the app's shadow engine and a replay of the file see bit-identical doubles.
public enum TraceNumber {
    private static let scales: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]
    private static let integerScales: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]

    /// Values beyond this many units (about 10^15) can't be stored and become 0. Real ones never are.
    private static let limit = 9e15

    public static func rounded(_ v: Double, _ decimals: Int) -> Double {
        let s = scales[decimals]
        guard v.isFinite, abs(v * s) < limit else { return 0 }
        return (v * s).rounded() / s
    }

    public static func rounded(_ p: CGPoint, _ decimals: Int) -> CGPoint {
        CGPoint(x: rounded(Double(p.x), decimals), y: rounded(Double(p.y), decimals))
    }

    public static func rounded(_ r: CGRect, _ decimals: Int) -> CGRect {
        CGRect(x: rounded(Double(r.minX), decimals), y: rounded(Double(r.minY), decimals),
               width: rounded(Double(r.width), decimals), height: rounded(Double(r.height), decimals))
    }

    /// Shortest text for the value at that many decimals: trailing zeros go.
    public static func format(_ v: Double, _ decimals: Int) -> String {
        let x = v * scales[decimals]
        let q = x.isFinite && abs(x) < limit ? Int64(x.rounded()) : 0
        guard decimals > 0 else { return String(q) }
        let p = integerScales[decimals]
        let m = q.magnitude
        var frac = String(m % UInt64(p))
        if frac != "0" {
            frac = String(repeating: "0", count: decimals - frac.count) + frac
            while frac.hasSuffix("0") { frac.removeLast() }
        } else {
            frac = ""
        }
        return (q < 0 ? "-" : "") + String(m / UInt64(p)) + (frac.isEmpty ? "" : "." + frac)
    }

    /// Nil for anything but `[-]digits[.digits]` with at most `decimals` fractional digits.
    public static func parse<S: StringProtocol>(_ s: S, _ decimals: Int) -> Double? {
        var negative = false, whole: Int64 = 0, frac: Int64 = 0, fracDigits = 0, digits = 0, inFraction = false
        for (i, c) in s.utf8.enumerated() {
            switch c {
            case UInt8(ascii: "-") where i == 0: negative = true
            case UInt8(ascii: ".") where !inFraction: inFraction = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let d = Int64(c - UInt8(ascii: "0"))
                digits += 1
                if inFraction {
                    fracDigits += 1
                    guard fracDigits <= decimals else { return nil }
                    frac = frac * 10 + d
                } else {
                    guard whole < 100_000_000_000 else { return nil }
                    whole = whole * 10 + d
                }
            default: return nil
            }
        }
        guard digits > 0 else { return nil }
        for _ in fracDigits..<decimals { frac *= 10 }
        let q = whole * integerScales[decimals] + frac
        return Double(negative ? -q : q) / scales[decimals]
    }
}

/// One head sample as recorded: raw, plus what the live path made of it.
public struct TraceSample: Equatable, Sendable {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// A look-away episode, screen saver or lock: the live path stopped before deciding.
        public static let gated = Flags(rawValue: 1)
        /// Calibration took the sample.
        public static let calibrating = Flags(rawValue: 2)
        /// No calibration: nothing was mapped.
        public static let uncalibrated = Flags(rawValue: 4)
    }

    public var host: TimeInterval            // uptime, comparable with NSEvent timestamps
    public var device: TimeInterval          // CMDeviceMotion.timestamp: the 1€ filter's clock
    public var yaw: Double
    public var pitch: Double
    public var speed: Double                 // raw gyro magnitude, °/s
    public var filteredYaw: Double?
    public var filteredPitch: Double?
    public var point: CGPoint?               // the live mapped point, CG space
    public var flags: Flags

    public init(host: TimeInterval, device: TimeInterval, yaw: Double, pitch: Double, speed: Double,
                filteredYaw: Double? = nil, filteredPitch: Double? = nil, point: CGPoint? = nil, flags: Flags = []) {
        self.host = TraceNumber.rounded(host, 4)
        self.device = TraceNumber.rounded(device, 5)
        self.yaw = TraceNumber.rounded(yaw, 4)
        self.pitch = TraceNumber.rounded(pitch, 4)
        self.speed = TraceNumber.rounded(speed, 2)
        self.filteredYaw = filteredYaw.map { TraceNumber.rounded($0, 4) }
        self.filteredPitch = filteredPitch.map { TraceNumber.rounded($0, 4) }
        self.point = point.map { TraceNumber.rounded($0, 1) }
        self.flags = flags
    }

    public init(_ s: HeadSample, filtered: (yaw: Double, pitch: Double)? = nil, point: CGPoint? = nil, flags: Flags = []) {
        self.init(host: s.hostTime, device: s.deviceTime, yaw: s.yaw, pitch: s.pitch, speed: s.speed,
                  filteredYaw: filtered?.yaw, filteredPitch: filtered?.pitch, point: point, flags: flags)
    }

    public var head: HeadSample {
        HeadSample(yaw: yaw, pitch: pitch, speed: speed, deviceTime: device, hostTime: host)
    }
}

/// A tracked window as recorded: no title, no app name, just what targeting uses.
public struct TraceWindow: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: Int32
    public var bundleID: String?
    public var frame: CGRect
    public var visibleFraction: Double
    public var target: CGPoint
    public var visibleRects: [CGRect]

    public init(id: CGWindowID, pid: Int32, bundleID: String?, frame: CGRect, visibleFraction: Double,
                target: CGPoint, visibleRects: [CGRect]) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID.map(TraceEvent.token)
        self.frame = TraceNumber.rounded(frame, 1)
        self.visibleFraction = TraceNumber.rounded(visibleFraction, 3)
        self.target = TraceNumber.rounded(target, 1)
        self.visibleRects = visibleRects.map { TraceNumber.rounded($0, 1) }
    }

    public init(_ w: TrackedWindow) {
        self.init(id: w.id, pid: w.pid, bundleID: w.bundleID, frame: w.frameCG, visibleFraction: w.visibleFraction,
                  target: w.targetPointCG, visibleRects: w.visibleRects)
    }

    /// As the targeting code sees it. The app name stands in from the bundle id.
    public var tracked: TrackedWindow {
        TrackedWindow(id: id, pid: pid, appName: bundleID ?? "pid \(pid)", bundleID: bundleID, frameCG: frame,
                      visibleRects: visibleRects, visibleFraction: visibleFraction, targetPointCG: target)
    }
}

/// Settings that shape behaviour, in the header.
public struct TraceSettings: Codable, Equatable, Sendable {
    public var sensitivity = SettingsDefault.sensitivity
    public var focusMode = SettingsDefault.focusMode.rawValue
    public var overlayMode = SettingsDefault.overlayMode.rawValue
    public var flickUp = SettingsDefault.flickUpEnabled
    public var flickSideways = SettingsDefault.flickSidewaysEnabled
    public var flickSensitivity = SettingsDefault.flickSensitivity
    public var missionControlPick = SettingsDefault.missionControlPick
    public var lookAway = SettingsDefault.lookAwayEnabled
    public var lookAwayDelay = SettingsDefault.lookAwayDelay
    public var simulated = false

    /// The defaults.
    public init() {}

    public init(_ s: AppSettings, simulated: Bool) {
        sensitivity = s.sensitivity
        focusMode = s.focusMode.rawValue
        overlayMode = s.overlayMode.rawValue
        flickUp = s.flickUpEnabled
        flickSideways = s.flickSidewaysEnabled
        flickSensitivity = s.flickSensitivity
        missionControlPick = s.missionControlPick
        lookAway = s.lookAwayEnabled
        lookAwayDelay = s.lookAwayDelay
        self.simulated = simulated
    }
}

/// Where things stood when a file began, so each file replays on its own.
public struct TraceState: Codable, Equatable, Sendable {
    public var current: UInt32?
    public var yawAnchored = true
    public var missionControl = false
    public var settingsHold = false
    public var away = false
    public var obscured = false
    public var calibrating = false

    public init() {}
}

/// The first event of every file.
public struct TraceHeader: Codable, Equatable, Sendable {
    public var format = TraceFormat.name
    public var version = TraceFormat.version
    public var app: String
    /// One run of the app: what the intent engine learned lasts this long.
    public var launch: String
    /// One tracking session; a session longer than an hour continues in numbered parts.
    public var session: String
    public var part: Int
    /// Wall clock and host uptime at the same instant, to place host times in the day.
    public var started: String
    public var uptime: Double
    public var displayKey: String
    public var screens: [CGRect]
    public var calibration: HeadCalibration?
    public var envelope: AngleEnvelope?
    public var calibrationSamples: Int
    public var settings: TraceSettings
    public var state: TraceState

    public init(app: String, launch: String, session: String, part: Int, started: String, uptime: Double, displayKey: String,
                screens: [CGRect], calibration: HeadCalibration?, settings: TraceSettings, state: TraceState) {
        self.app = app
        self.launch = launch
        self.session = session
        self.part = part
        self.started = started
        self.uptime = TraceNumber.rounded(uptime, 4)
        self.displayKey = displayKey
        let rounded = screens.map { TraceNumber.rounded($0, 1) }
        self.screens = rounded
        self.calibration = calibration
        self.envelope = calibration?.envelope(screensCG: rounded)
        self.calibrationSamples = calibration?.samples.count ?? 0
        self.settings = settings
        self.state = state
    }
}

/// One line of a trace.
public enum TraceEvent: Equatable, Sendable {
    public enum Source: String, Sendable { case request = "req", external = "ext" }
    public enum FocusReason: String, Sendable { case dwell, hotkey }
    public enum Button: String, Sendable { case left = "l", right = "r" }
    public enum CalibrationChange: String, Sendable { case calibrated, recenter, nudge, anchor, reload, cleared }
    public enum Stream: String, Sendable { case started, restarted, jump, connected, disconnected, unanchored, anchored }
    public enum Mode: String, Sendable {
        case away, obscured, settings, calibrating, missionControl = "mc", pick, flickHold, missionControlHold = "mcHold", overlay
    }

    case header(TraceHeader)
    case sample(TraceSample)
    /// The tracked windows, front to back, whenever the list changes.
    case windows(TimeInterval, [TraceWindow])
    /// Every window poll: the window in front and whether Mission Control is open.
    case poll(TimeInterval, front: LiveSwitcher.Front, missionControl: Bool)
    /// The front window changed: because we asked, or because the user did.
    case front(TimeInterval, CGWindowID?, Source)
    /// A live focus request: a dwell switch, or ⌃⌥⌘F.
    case focusRequest(TimeInterval, CGWindowID, FocusReason)
    case focusResult(TimeInterval, CGWindowID, verified: Bool)
    /// The live selector's reject, when it changes.
    case reject(TimeInterval, TargetSelector.Reject?)
    /// A key went down. Never which one.
    case key(TimeInterval)
    /// A mouse button went down, at a CG point, over this tracked window.
    case click(TimeInterval, Button, CGPoint, CGWindowID?)
    /// The calibration changed; the new one in full, so a replay maps poses exactly as live did.
    case calibration(TimeInterval, CalibrationChange, CGWindowID?, HeadCalibration?)
    case stream(TimeInterval, Stream, String)
    case mode(TimeInterval, Mode, Bool, String)
    case flick(TimeInterval, FlickDetector.Burst)
    case config(TimeInterval, LiveConfig)
    case tracking(TimeInterval, Bool)
    case display(TimeInterval, key: String, screens: [CGRect])
    /// The intent engine, in shadow mode, would have switched here.
    case intent(TimeInterval, CGWindowID, evidence: Double, threshold: Double)
    case end(TimeInterval)

    public var time: TimeInterval {
        switch self {
        case .header(let h): return h.uptime
        case .sample(let s): return s.host
        case .windows(let t, _), .poll(let t, _, _), .front(let t, _, _), .focusRequest(let t, _, _),
             .focusResult(let t, _, _), .reject(let t, _), .key(let t), .click(let t, _, _, _),
             .calibration(let t, _, _, _), .stream(let t, _, _), .mode(let t, _, _, _), .flick(let t, _),
             .config(let t, _), .tracking(let t, _), .display(let t, _, _), .intent(let t, _, _, _), .end(let t):
            return t
        }
    }

    /// No spaces, commas, slashes or line breaks: bundle ids and free text stay one field.
    static func token(_ s: String) -> String {
        String(s.map { " ,/\n\r\t".contains($0) ? "_" : $0 })
    }

    private static func detailText(_ s: String) -> String {
        String(s.map { $0.isNewline ? " " : $0 })
    }

    private static func time(_ t: TimeInterval) -> String { TraceNumber.format(t, 4) }
    private static func id(_ id: CGWindowID?) -> String { id.map { String($0) } ?? "-" }
    private static func rect(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { TraceNumber.format(Double($0), 1) }.joined(separator: ":")
    }
    private static func flag(_ b: Bool) -> String { b ? "1" : "0" }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: Encoding

    public var line: String {
        switch self {
        case .header(let h):
            let json = (try? Self.jsonEncoder.encode(h)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "H " + json
        case .sample(let s):
            var f = ""
            if s.flags.contains(.gated) { f += "g" }
            if s.flags.contains(.calibrating) { f += "c" }
            if s.flags.contains(.uncalibrated) { f += "n" }
            let filtered = [s.filteredYaw.map { TraceNumber.format($0, 4) } ?? "-",
                            s.filteredPitch.map { TraceNumber.format($0, 4) } ?? "-",
                            s.point.map { TraceNumber.format(Double($0.x), 1) } ?? "-",
                            s.point.map { TraceNumber.format(Double($0.y), 1) } ?? "-"]
            return (["s", Self.time(s.host), TraceNumber.format(s.device, 5), TraceNumber.format(s.yaw, 4),
                     TraceNumber.format(s.pitch, 4), TraceNumber.format(s.speed, 2)] + filtered + [f.isEmpty ? "-" : f])
                .joined(separator: " ")
        case .windows(let t, let ws):
            let items = ws.map { w in
                [String(w.id), String(w.pid), w.bundleID ?? "-", Self.rect(w.frame).replacingOccurrences(of: ":", with: ","),
                 TraceNumber.format(w.visibleFraction, 3), TraceNumber.format(Double(w.target.x), 1),
                 TraceNumber.format(Double(w.target.y), 1), w.visibleRects.map(Self.rect).joined(separator: "/")]
                    .joined(separator: ",")
            }
            return (["w", Self.time(t), String(ws.count)] + items).joined(separator: " ")
        case .poll(let t, let front, let mc):
            let f: String
            switch front {
            case .unknown: f = "-"
            case .own: f = "own"
            case .window(let id): f = String(id)
            }
            return "p \(Self.time(t)) \(f) \(Self.flag(mc))"
        case .front(let t, let id, let source):
            return "f \(Self.time(t)) \(Self.id(id)) \(source.rawValue)"
        case .focusRequest(let t, let id, let reason):
            return "q \(Self.time(t)) \(id) \(reason.rawValue)"
        case .focusResult(let t, let id, let ok):
            return "r \(Self.time(t)) \(id) \(ok ? "ok" : "fail")"
        case .reject(let t, let reject):
            return "x \(Self.time(t)) \(reject?.rawValue ?? "-")"
        case .key(let t):
            return "k \(Self.time(t))"
        case .click(let t, let button, let p, let id):
            return "m \(Self.time(t)) \(button.rawValue) \(TraceNumber.format(Double(p.x), 1)) \(TraceNumber.format(Double(p.y), 1)) \(Self.id(id))"
        case .calibration(let t, let kind, let id, let cal):
            let json = cal.flatMap { try? Self.jsonEncoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return "C \(Self.time(t)) \(kind.rawValue) \(Self.id(id)) \(json)"
        case .stream(let t, let kind, let detail):
            return "S \(Self.time(t)) \(kind.rawValue)" + (detail.isEmpty ? "" : " " + Self.detailText(detail))
        case .mode(let t, let kind, let on, let detail):
            return "M \(Self.time(t)) \(kind.rawValue) \(Self.flag(on))" + (detail.isEmpty ? "" : " " + Self.detailText(detail))
        case .flick(let t, let b):
            return ["g", Self.time(t), b.direction?.rawValue ?? "down", TraceNumber.format(b.peakRate, 1),
                    TraceNumber.format(b.amplitude, 2), TraceNumber.format(b.crossAmplitude, 2),
                    TraceNumber.format(b.rise, 3), TraceNumber.format(b.duration, 3),
                    b.rejection.map { "\($0)" } ?? "fired"].joined(separator: " ")
        case .config(let t, let c):
            return "c \(Self.time(t)) sens=\(c.sensitivity) auto=\(Self.flag(c.automatic)) paused=\(Self.flag(c.switchingPaused)) "
                + "hold=\(Self.flag(c.settingsHold)) up=\(Self.flag(c.flickUp)) side=\(Self.flag(c.flickSideways)) "
                + "fsens=\(c.flickSensitivity) sim=\(Self.flag(c.simulated))"
        case .tracking(let t, let on):
            return "T \(Self.time(t)) \(on ? "start" : "stop")"
        case .display(let t, let key, let screens):
            return "D \(Self.time(t)) \(screens.map(Self.rect).joined(separator: "/")) \(String(key.map { $0.isWhitespace ? "_" : $0 }))"
        case .intent(let t, let id, let evidence, let threshold):
            return "i \(Self.time(t)) \(id) \(TraceNumber.format(evidence, 2)) \(TraceNumber.format(threshold, 2))"
        case .end(let t):
            return "E \(Self.time(t))"
        }
    }

    // MARK: Decoding

    /// Nil for comments, blank lines, unknown codes (a newer format) and malformed lines.
    public init?(line raw: Substring) {
        let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
        guard let code = line.first, code != "#" else { return nil }
        if code == "H" {
            guard line.hasPrefix("H "),
                  let h = try? JSONDecoder().decode(TraceHeader.self, from: Data(line.dropFirst(2).utf8)) else { return nil }
            self = .header(h)
            return
        }
        let f = line.split(separator: " ", omittingEmptySubsequences: false)
        guard f.count >= 2, f[0].count == 1, let t = TraceNumber.parse(f[1], 4) else { return nil }
        func num(_ i: Int, _ d: Int) -> Double? { f.indices.contains(i) ? TraceNumber.parse(f[i], d) : nil }
        func wid(_ i: Int) -> CGWindowID?? {
            guard f.indices.contains(i) else { return nil }
            if f[i] == "-" { return .some(nil) }
            return UInt32(f[i]).map { .some($0) }
        }
        func rest(from i: Int) -> String { f.count > i ? f[i...].joined(separator: " ") : "" }
        func bool(_ i: Int) -> Bool? { f.indices.contains(i) ? (f[i] == "1" ? true : (f[i] == "0" ? false : nil)) : nil }

        switch code {
        case "s":
            guard f.count == 11, let dev = num(2, 5), let yaw = num(3, 4), let pitch = num(4, 4), let speed = num(5, 2)
            else { return nil }
            var flags = TraceSample.Flags()
            if f[10].contains("g") { flags.insert(.gated) }
            if f[10].contains("c") { flags.insert(.calibrating) }
            if f[10].contains("n") { flags.insert(.uncalibrated) }
            let point = num(8, 1).flatMap { x in num(9, 1).map { CGPoint(x: x, y: $0) } }
            self = .sample(TraceSample(host: t, device: dev, yaw: yaw, pitch: pitch, speed: speed,
                                       filteredYaw: num(6, 4), filteredPitch: num(7, 4), point: point, flags: flags))
        case "w":
            guard f.count >= 3, let n = Int(f[2]), f.count == 3 + n else { return nil }
            var windows: [TraceWindow] = []
            for item in f[3...] {
                let p = item.split(separator: ",", omittingEmptySubsequences: false)
                guard p.count == 11, let id = UInt32(p[0]), let pid = Int32(p[1]),
                      let x = TraceNumber.parse(p[3], 1), let y = TraceNumber.parse(p[4], 1),
                      let w = TraceNumber.parse(p[5], 1), let h = TraceNumber.parse(p[6], 1),
                      let frac = TraceNumber.parse(p[7], 3), let tx = TraceNumber.parse(p[8], 1),
                      let ty = TraceNumber.parse(p[9], 1) else { return nil }
                var rects: [CGRect] = []
                for r in p[10].split(separator: "/") {
                    let c = r.split(separator: ":").compactMap { TraceNumber.parse($0, 1) }
                    guard c.count == 4 else { return nil }
                    rects.append(CGRect(x: c[0], y: c[1], width: c[2], height: c[3]))
                }
                windows.append(TraceWindow(id: id, pid: pid, bundleID: p[2] == "-" ? nil : String(p[2]),
                                           frame: CGRect(x: x, y: y, width: w, height: h), visibleFraction: frac,
                                           target: CGPoint(x: tx, y: ty), visibleRects: rects))
            }
            self = .windows(t, windows)
        case "p":
            guard f.count == 4, let mc = bool(3) else { return nil }
            let front: LiveSwitcher.Front
            switch f[2] {
            case "-": front = .unknown
            case "own": front = .own
            default:
                guard let id = UInt32(f[2]) else { return nil }
                front = .window(id)
            }
            self = .poll(t, front: front, missionControl: mc)
        case "f":
            guard f.count == 4, let id = wid(2), let source = Source(rawValue: String(f[3])) else { return nil }
            self = .front(t, id, source)
        case "q":
            guard f.count == 4, let id = UInt32(f[2]), let reason = FocusReason(rawValue: String(f[3])) else { return nil }
            self = .focusRequest(t, id, reason)
        case "r":
            guard f.count == 4, let id = UInt32(f[2]), f[3] == "ok" || f[3] == "fail" else { return nil }
            self = .focusResult(t, id, verified: f[3] == "ok")
        case "x":
            guard f.count == 3 else { return nil }
            if f[2] == "-" {
                self = .reject(t, nil)
            } else {
                guard let r = TargetSelector.Reject(rawValue: String(f[2])) else { return nil }
                self = .reject(t, r)
            }
        case "k":
            guard f.count == 2 else { return nil }
            self = .key(t)
        case "m":
            guard f.count == 6, let button = Button(rawValue: String(f[2])), let x = num(3, 1), let y = num(4, 1),
                  let id = wid(5) else { return nil }
            self = .click(t, button, CGPoint(x: x, y: y), id)
        case "C":
            guard f.count >= 5, let kind = CalibrationChange(rawValue: String(f[2])), let id = wid(3) else { return nil }
            let json = rest(from: 4)
            if json == "null" {
                self = .calibration(t, kind, id, nil)
            } else {
                guard let cal = try? JSONDecoder().decode(HeadCalibration.self, from: Data(json.utf8)) else { return nil }
                self = .calibration(t, kind, id, cal)
            }
        case "S":
            guard f.count >= 3, let kind = Stream(rawValue: String(f[2])) else { return nil }
            self = .stream(t, kind, rest(from: 3))
        case "M":
            guard f.count >= 4, let kind = Mode(rawValue: String(f[2])), let on = bool(3) else { return nil }
            self = .mode(t, kind, on, rest(from: 4))
        case "g":
            guard f.count == 9, let peak = num(3, 1), let amp = num(4, 2), let cross = num(5, 2), let rise = num(6, 3),
                  let dur = num(7, 3) else { return nil }
            let direction = f[2] == "down" ? nil : FlickDetector.Direction(rawValue: String(f[2]))
            guard direction != nil || f[2] == "down" else { return nil }
            let rejection = f[8] == "fired" ? nil : FlickDetector.Rejection.allCases.first { "\($0)" == f[8] }
            guard rejection != nil || f[8] == "fired" else { return nil }
            self = .flick(t, FlickDetector.Burst(direction: direction, peakRate: peak, amplitude: amp, crossAmplitude: cross,
                                                 rise: rise, duration: dur, rejection: rejection))
        case "c":
            var c = LiveConfig()
            for pair in f.dropFirst(2) {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { return nil }
                let v = kv[1]
                switch kv[0] {
                case "sens": guard let d = Double(v) else { return nil }; c.sensitivity = d
                case "fsens": guard let d = Double(v) else { return nil }; c.flickSensitivity = d
                case "auto": c.automatic = v == "1"
                case "paused": c.switchingPaused = v == "1"
                case "hold": c.settingsHold = v == "1"
                case "up": c.flickUp = v == "1"
                case "side": c.flickSideways = v == "1"
                case "sim": c.simulated = v == "1"
                default: break       // a newer field
                }
            }
            self = .config(t, c)
        case "T":
            guard f.count == 3, f[2] == "start" || f[2] == "stop" else { return nil }
            self = .tracking(t, f[2] == "start")
        case "D":
            guard f.count == 4 else { return nil }
            var screens: [CGRect] = []
            for r in f[2].split(separator: "/") {
                let c = r.split(separator: ":").compactMap { TraceNumber.parse($0, 1) }
                guard c.count == 4 else { return nil }
                screens.append(CGRect(x: c[0], y: c[1], width: c[2], height: c[3]))
            }
            self = .display(t, key: String(f[3]), screens: screens)
        case "i":
            guard f.count == 5, let id = UInt32(f[2]), let e = num(3, 2), let th = num(4, 2) else { return nil }
            self = .intent(t, id, evidence: e, threshold: th)
        case "E":
            self = .end(t)
        default:
            return nil
        }
    }

    /// Every event in a trace's text, in order, and how many lines were skipped as malformed or unknown.
    public static func parse(_ text: String) -> (events: [TraceEvent], skipped: Int) {
        var events: [TraceEvent] = []
        var skipped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let e = TraceEvent(line: line) {
                events.append(e)
            } else if !line.hasPrefix("#") {
                skipped += 1
            }
        }
        return (events, skipped)
    }
}
