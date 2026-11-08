import CoreGraphics
import XCTest
@testable import AirFocusCore

final class TraceFormatTests: XCTestCase {
    private let calibration: HeadCalibration = {
        let map = AffineHeadMap(a: [1244.123456789, -64.0000001, 3.3], b: [0.25, -2.1, -60.987654321])
        let samples = [CGPoint(x: 1280, y: 720), CGPoint(x: 300, y: 200), CGPoint(x: 2200, y: 1200)].map { p -> CalibrationSample in
            let a = map.angles(for: p)!
            return CalibrationSample(yaw: a.yaw, pitch: a.pitch, screen: p)
        }
        return HeadCalibration(map: map, samples: samples, anchors: [WindowAnchor(windowID: 7, dotCG: CGPoint(x: 640.5, y: 400), yaw: 9.87654, pitch: -11.1)],
                               displayKey: "1-2-3@0,0,2560x1440", createdAt: Date(timeIntervalSinceReferenceDate: 812_345_678.25))
    }()

    func testFixedPointFormatsAndParsesExactly() {
        for (v, d, text) in [(3.25, 4, "3.25"), (-0.0001, 4, "-0.0001"), (0, 4, "0"), (412345.6789, 4, "412345.6789"),
                             (-12.30001, 4, "-12.3"), (1.5, 0, "2"), (99.99, 1, "100")] as [(Double, Int, String)] {
            XCTAssertEqual(TraceNumber.format(v, d), text, "\(v)")
        }
        for _ in 0..<2000 {
            let v = Double.random(in: -500_000...500_000)
            for d in [1, 2, 3, 4, 5] {
                let r = TraceNumber.rounded(v, d)
                XCTAssertEqual(TraceNumber.parse(TraceNumber.format(v, d), d), r, "\(v) at \(d)")
                XCTAssertEqual(TraceNumber.format(r, d), TraceNumber.format(v, d), "rounding twice changes nothing")
            }
        }
        for huge in [Double.infinity, -.infinity, .nan, 1e300, -4e17] {
            XCTAssertEqual(TraceNumber.format(huge, 4), "0", "no trap on \(huge)")
            XCTAssertEqual(TraceNumber.rounded(huge, 4), 0)
        }
        for bad in ["", "-", ".", "1.2.3", "1e5", "nan", "--1", "1,5", "0.123456"] {
            XCTAssertNil(TraceNumber.parse(bad, 4), bad)
        }
    }

    /// The app's shadow engine reads values straight from the event; a replay reads them from the
    /// line. Both must be the same doubles, bit for bit.
    func testASampleIsTheSameAfterARoundTripThroughText() throws {
        for _ in 0..<500 {
            let s = TraceSample(host: Double.random(in: 1000...900_000), device: Double.random(in: 1000...900_000),
                                yaw: Double.random(in: -200...200), pitch: Double.random(in: -90...90), speed: Double.random(in: 0...400),
                                filteredYaw: Double.random(in: -200...200), filteredPitch: Double.random(in: -90...90),
                                point: CGPoint(x: Double.random(in: -3000...6000), y: Double.random(in: -2000...3000)),
                                flags: [.gated])
            let line = TraceEvent.sample(s).line
            guard case .sample(let back)? = TraceEvent(line: Substring(line)) else { return XCTFail(line) }
            XCTAssertEqual(back, s, line)
            XCTAssertEqual(back.yaw.bitPattern, s.yaw.bitPattern)
            XCTAssertEqual(back.host.bitPattern, s.host.bitPattern)
        }
        let bare = TraceSample(host: 5, device: 4.99, yaw: 1, pitch: -2, speed: 3, flags: .calibrating)
        XCTAssertEqual(TraceEvent.sample(bare).line, "s 5 4.99 1 -2 3 - - - - c")
        XCTAssertEqual(TraceEvent(line: "s 5 4.99 1 -2 3 - - - - c"), .sample(bare))
    }

    func testEveryEventRoundTrips() throws {
        let window = TraceWindow(id: 42, pid: 311, bundleID: "com.googlecode.iterm2", frame: CGRect(x: -1280, y: 25, width: 1280.5, height: 800),
                                 visibleFraction: 0.8765, target: CGPoint(x: -640.25, y: 400),
                                 visibleRects: [CGRect(x: -1280, y: 25, width: 1000, height: 800), CGRect(x: -280, y: 25, width: 280.5, height: 300)])
        var config = LiveConfig()
        config.sensitivity = 0.143
        config.automatic = false
        config.switchingPaused = true
        config.flickSensitivity = 0.6000000000000001
        config.simulated = true
        let burst = FlickDetector.Burst(direction: .left, peakRate: 212.3, amplitude: 18.25, crossAmplitude: 2.5, rise: 0.081,
                                        duration: 0.22, rejection: .returnStroke)
        var state = TraceState()
        state.current = 42
        state.yawAnchored = false
        let header = TraceHeader(app: "0.1.0 (1)", launch: "123-456", session: "2026-11-07T13-40-12", part: 2, started: "2026-11-07T12:40:12Z",
                                 uptime: 4123.45678, displayKey: calibration.displayKey, screens: [CGRect(x: 0, y: 0, width: 2560, height: 1440)],
                                 calibration: calibration, settings: TraceSettings(), state: state)
        let events: [TraceEvent] = [
            .header(header),
            .windows(10, [window, TraceWindow(id: 1, pid: 2, bundleID: nil, frame: .zero, visibleFraction: 1, target: .zero, visibleRects: [])]),
            .windows(10.5, []),
            .poll(11, front: .window(42), missionControl: true), .poll(11.125, front: .own, missionControl: false),
            .poll(11.25, front: .unknown, missionControl: false),
            .front(12, 42, .external), .front(12.1, nil, .request),
            .focusRequest(13, 42, .dwell), .focusRequest(13.5, 7, .hotkey),
            .focusResult(14, 42, verified: true), .focusResult(14.2, 7, verified: false),
            .reject(15, .typing), .reject(15.5, nil),
            .key(16.0001),
            .click(17, .right, CGPoint(x: 100.5, y: -20), 42), .click(17.5, .left, CGPoint(x: 1, y: 2), nil),
            .calibration(18, .recenter, 42, calibration), .calibration(18.5, .cleared, nil, nil),
            .stream(19, .unanchored, "reference jump (streaming bud changed (Δyaw 3.0°, Δpitch 1.0°))"), .stream(19.5, .connected, ""),
            .mode(20, .missionControl, true, ""), .mode(20.5, .calibrating, false, "cancelled"), .mode(21, .flickHold, true, "1.6 s"),
            .flick(22, burst), .flick(22.5, FlickDetector.Burst(direction: nil, peakRate: 120, amplitude: 9, crossAmplitude: 1, rise: 0.1,
                                                                 duration: 0.3, rejection: .down)),
            .flick(22.75, FlickDetector.Burst(direction: .up, peakRate: 150, amplitude: 12, crossAmplitude: 1, rise: 0.1, duration: 0.2, rejection: nil)),
            .config(23, config),
            .tracking(24, true), .tracking(25, false),
            .display(26, key: "a@0,0,1x1|b@-10,0,5x5", screens: [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -1920, y: -200, width: 1920, height: 1080)]),
            .intent(27, 42, evidence: 15.27, threshold: 15),
            .end(28),
        ]
        for e in events {
            let line = e.line
            XCTAssertFalse(line.contains("\n"), line)
            XCTAssertEqual(TraceEvent(line: Substring(line)), e, line)
        }
        let parsed = TraceEvent.parse(([TraceFormat.banner] + events.map(\.line) + ["", "# a comment", "Z 1 future", "s broken"]).joined(separator: "\n"))
        XCTAssertEqual(parsed.events, events)
        XCTAssertEqual(parsed.skipped, 2, "an unknown code and a malformed line; comments and blanks don't count")
    }

    /// The replay has to map poses exactly as live did, so the calibration survives JSON bit for bit.
    func testCalibrationSurvivesTheTraceExactly() throws {
        let line = TraceEvent.calibration(1, .nudge, nil, calibration).line
        guard case .calibration(_, _, _, let back?)? = TraceEvent(line: Substring(line)) else { return XCTFail(line) }
        XCTAssertEqual(back, calibration)
        for i in 0..<3 {
            XCTAssertEqual(back.map.a[i].bitPattern, calibration.map.a[i].bitPattern)
            XCTAssertEqual(back.map.b[i].bitPattern, calibration.map.b[i].bitPattern)
        }
        XCTAssertEqual(back.lowestCalibratedPitch, calibration.lowestCalibratedPitch)
    }

    /// Nothing about what was typed or shown: a key line is a time, a window is geometry and a bundle id.
    func testTracesCarryNoKeyIdentityOrTitles() {
        XCTAssertEqual(TraceEvent.key(12.5).line, "k 12.5")
        let w = TrackedWindow(id: 9, pid: 4, appName: "Secret Project — Terminal", bundleID: "com.apple.Terminal",
                              frameCG: CGRect(x: 0, y: 0, width: 800, height: 600), visibleRects: [CGRect(x: 0, y: 0, width: 800, height: 600)],
                              visibleFraction: 1, targetPointCG: CGPoint(x: 400, y: 300))
        let line = TraceEvent.windows(1, [TraceWindow(w)]).line
        XCTAssertFalse(line.contains("Secret"), line)
        XCTAssertTrue(line.contains("com.apple.Terminal"))
    }

    func testBundleIDsAndDetailsCannotBreakTheLine() {
        let w = TraceWindow(id: 1, pid: 1, bundleID: "odd id,with/separators", frame: .zero, visibleFraction: 1, target: .zero, visibleRects: [])
        guard case .windows(_, let back)? = TraceEvent(line: Substring(TraceEvent.windows(1, [w]).line)) else { return XCTFail() }
        XCTAssertEqual(back.first?.bundleID, "odd_id_with_separators")
        let e = TraceEvent.stream(2, .jump, "two\nlines")
        XCTAssertEqual(TraceEvent(line: Substring(e.line)), .stream(2, .jump, "two lines"))
    }

    // MARK: Gzip

    func testGzipRoundTripsAndChecksItsCRC() throws {
        let text = TraceSynthesizer.text(Array(TraceSynthesizer.events([.boundaryJitter], seed: 3).prefix(4000)))
        let data = Data(text.utf8)
        let gz = try XCTUnwrap(Gzip.compress(data))
        XCTAssertTrue(Gzip.isGzip(gz))
        XCTAssertLessThan(gz.count, data.count / 2, "traces compress well")
        XCTAssertEqual(Gzip.decompress(gz), data)
        var corrupt = gz
        corrupt[corrupt.count - 6] ^= 0xFF          // the CRC
        XCTAssertNil(Gzip.decompress(corrupt))
        XCTAssertNil(Gzip.decompress(Data("not gzip".utf8)))
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926, "the standard check value")
    }

    /// Files gzipped by other tools carry a name field; it is skipped.
    func testGzipWithAFileNameField() throws {
        let data = Data("k 1\nk 2\n".utf8)
        var gz = try XCTUnwrap(Gzip.compress(data))
        gz[3] = 0x08                                  // FNAME
        gz.insert(contentsOf: Array("trace.aftrace".utf8) + [0], at: 10)
        XCTAssertEqual(Gzip.decompress(gz), data)
    }

    func testTraceFilesReadPlainOrGzipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aftrace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let events: [TraceEvent] = [.tracking(1, true), .key(2), .tracking(3, false)]
        let text = TraceSynthesizer.text(events)
        try Data(text.utf8).write(to: dir.appendingPathComponent("b-p1.aftrace"))
        try XCTUnwrap(Gzip.compress(Data(text.utf8))).write(to: dir.appendingPathComponent("a-p1.aftrace.gz"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let files = TraceFile.list(dir.path)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a-p1.aftrace.gz", "b-p1.aftrace"])
        for f in files { XCTAssertEqual(TraceFile.read(f)?.events, events) }
    }
}
