import CoreGraphics
import XCTest
@testable import AirFocusCore

/// Both engines over synthetic traces. These are simulations: they show the engines behave as
/// designed on the behaviours the scenarios model, not that intent wins on real use. Real traces decide that.
final class TraceReplayTests: XCTestCase {
    private static let seeds: [UInt64] = [1, 2]
    /// Recorded the way the app records, written to text and read back, as a replay would.
    private static let traces: [[TraceEvent]] = seeds.map { seed in
        TraceEvent.parse(TraceSynthesizer.text(TraceSynthesizer.events(seed: seed))).events
    }
    private static let replays: [TraceReplay] = traces.map { events in
        var r = TraceReplay()
        r.feed(events)
        r.finish()
        return r
    }

    private func sessions(_ r: TraceReplay, _ scenarios: [TraceSynthesizer.Scenario]) -> TraceReplay.SessionReport {
        var t = TraceReplay.SessionReport(label: "subset")
        for s in r.sessions where scenarios.map(\.rawValue).contains(s.label) {
            t.live.merge(s.live)
            t.intent.merge(s.intent)
        }
        return t
    }

    func testEveryScenarioReplaysAsASession() {
        for r in Self.replays {
            XCTAssertEqual(r.sessions.map(\.label), TraceSynthesizer.Scenario.allCases.map(\.rawValue))
            XCTAssertEqual(r.skippedLines, 0)
        }
    }

    /// The replayed live path makes exactly the decisions the recording says live made, and the
    /// replayed intent engine exactly those its shadow made.
    func testReplayMatchesTheRecordingExactly() {
        for r in Self.replays {
            let f = r.fidelity
            XCTAssertGreaterThan(f.recordedLive.count, 50)
            XCTAssertEqual(f.replayedLive.count, f.recordedLive.count)
            XCTAssertEqual(TraceReplay.exactMatches(f.recordedLive, f.replayedLive, within: 0.001), f.recordedLive.count)
            XCTAssertLessThan(f.maxFilterDelta, 0.001, "four decimals of raw pose in the trace")
            XCTAssertLessThan(f.maxPointDelta, 0.2)
            XCTAssertGreaterThan(f.recordedIntent.count, 50)
            XCTAssertEqual(TraceReplay.exactMatches(f.recordedIntent, f.replayedIntent, within: 0), f.recordedIntent.count)
            XCTAssertEqual(f.replayedIntent.count, f.recordedIntent.count)
        }
    }

    func testReplayIsDeterministic() {
        var again = TraceReplay()
        again.feed(Self.traces[0])
        again.finish()
        XCTAssertEqual(again.table(), Self.replays[0].table())
    }

    /// Where every switch is a mistake (glancing while typing, drift while typing, reading on an edge),
    /// intent makes fewer of them, bounces less and switches less during typing.
    func testIntentBeatsLiveOnBouncesAndTypingSwitches() {
        for r in Self.replays {
            let wrong = sessions(r, [.typingGlances, .driftWhileTyping, .boundaryJitter])
            XCTAssertLessThan(wrong.intent.switches.count * 2, wrong.live.switches.count, "at most half the wrong switches")
            XCTAssertLessThan(wrong.intent.tally.bounces, wrong.live.tally.bounces)
            XCTAssertLessThan(wrong.intent.tally.typing, wrong.live.tally.typing)
            let total = r.total
            XCTAssertLessThan(total.intent.bounceRate, total.live.bounceRate)
            XCTAssertLessThan(total.intent.tally.typing, total.live.tally.typing)
            XCTAssertLessThanOrEqual(sessions(r, [.driftWhileTyping, .boundaryJitter]).intent.switches.count, 1)
        }
    }

    /// Where every switch is meant (turning to another window, then typing or reading there), intent
    /// is not meaningfully slower and misses no more than live does.
    func testIntentIsNotMeaningfullySlowerOnCleanSwitches() throws {
        for r in Self.replays {
            let clean = sessions(r, [.cleanSwitches, .settleWithoutTyping])
            let live = try XCTUnwrap(clean.live.medianLatency), intent = try XCTUnwrap(clean.intent.medianLatency)
            XCTAssertLessThanOrEqual(intent, live + 0.15, "live \(live), intent \(intent)")
            XCTAssertLessThanOrEqual(intent, 0.45, "as fast as the 450 ms dwell")
            XCTAssertGreaterThanOrEqual(clean.intent.switches.count, clean.live.switches.count)
            XCTAssertLessThanOrEqual(clean.intent.missed, clean.live.missed)
        }
    }

    /// After a restart, a settled click anchors intent's yaw (logged, as it could replace ⌃⌥⌘R), and
    /// it switches from then on.
    func testAStreamRestartIsAnchoredByAClick() throws {
        var runner = IntentRunner()
        var anchoredAt: TimeInterval?
        var switches: [TimeInterval] = []
        for e in TraceSynthesizer.events([.restartThenClick], seed: 1) {
            for out in runner.consume(e) {
                if case .note(let t, .clickAnchoredYaw) = out, anchoredAt == nil { anchoredAt = t }
                if case .wouldSwitch(let t, _, _, _, _, _, _, _, _) = out { switches.append(t) }
            }
        }
        let anchored = try XCTUnwrap(anchoredAt)
        XCTAssertEqual(anchored, 1000 + 3.6, accuracy: 0.1, "the first click, before any typing")
        XCTAssertTrue(switches.allSatisfy { $0 > anchored }, "nothing yaw-based before the anchor")
        XCTAssertGreaterThan(switches.count, 8)
    }

    /// The app logs a live-versus-intent comparison every ten minutes of tracking.
    func testTheShadowSummaryComesEveryTenMinutes() {
        var runner = IntentRunner(summaries: true)
        var lines: [String] = []
        for e in Self.traces[0] {
            for case .summary(let line) in runner.consume(e) { lines.append(line) }
        }
        XCTAssertGreaterThanOrEqual(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("last 10 min: live ") && $0.contains(" · intent ") && $0.contains("bounced") }, "\(lines)")
    }

    // MARK: The runner's gates

    func testTheRunnerAppliesTheLiveGates() {
        let w = [TraceWindow(TrackedWindow(id: 1, frameCG: CGRect(x: 0, y: 0, width: 1280, height: 1440))),
                 TraceWindow(TrackedWindow(id: 2, frameCG: CGRect(x: 1280, y: 0, width: 1280, height: 1440)))]
        var runner = IntentRunner()
        let header = TraceHeader(app: "t", launch: "l", session: "s", part: 1, started: "", uptime: 0, displayKey: "",
                                 screens: [CGRect(x: 0, y: 0, width: 2560, height: 1440)], calibration: TraceSynthesizer.calibration,
                                 settings: TraceSettings(), state: TraceState())
        for e: TraceEvent in [.header(header), .tracking(0, true), .windows(0, w), .poll(0, front: .window(1), missionControl: false)] {
            _ = runner.consume(e)
        }
        func gate(_ s: TraceSample) -> IntentEngine.Gate? { runner.gate(for: s) }
        let s = TraceSample(host: 1, device: 1, yaw: 0, pitch: -12, speed: 1, filteredYaw: 0, filteredPitch: -12, point: .zero)
        XCTAssertNil(gate(s))
        XCTAssertEqual(gate(TraceSample(host: 1, device: 1, yaw: 0, pitch: 0, speed: 0, flags: .calibrating)), .calibrating)
        XCTAssertEqual(gate(TraceSample(host: 1, device: 1, yaw: 0, pitch: 0, speed: 0, filteredYaw: 0, filteredPitch: 0, flags: .gated)), .away)
        _ = runner.consume(.flick(1, FlickDetector.Burst(direction: .up, peakRate: 150, amplitude: 12, crossAmplitude: 1, rise: 0.1,
                                                         duration: 0.2, rejection: nil)))
        XCTAssertEqual(gate(s), .flickHold)
        let later = TraceSample(host: 2.7, device: 2.7, yaw: 0, pitch: -12, speed: 1, filteredYaw: 0, filteredPitch: -12, point: .zero)
        XCTAssertNil(gate(later), "1.6 s after the flick")
        _ = runner.consume(.mode(3, .settings, true, ""))
        XCTAssertEqual(gate(later), .settings)
        _ = runner.consume(.mode(3, .settings, false, ""))
        var hotkey = LiveConfig()
        hotkey.automatic = false
        _ = runner.consume(.config(3, hotkey))
        XCTAssertEqual(gate(later), .hotkeyOnly)
        _ = runner.consume(.config(3, LiveConfig()))
        _ = runner.consume(.poll(4, front: .window(1), missionControl: true))
        XCTAssertEqual(gate(later), .missionControl)
        _ = runner.consume(.poll(5, front: .window(2), missionControl: false))
        XCTAssertEqual(runner.engine.current, 2, "Mission Control closed: what came forward is adopted")
        XCTAssertEqual(gate(TraceSample(host: 5.3, device: 5.3, yaw: 0, pitch: -12, speed: 1, filteredYaw: 0, filteredPitch: -12, point: .zero)),
                       .flickHold, "and held for 0.6 s")
    }

    // MARK: Metrics

    private func sw(_ t: Double, _ from: CGWindowID?, _ to: CGWindowID, latency: Double? = nil) -> SwitchMetrics.Switch {
        SwitchMetrics.Switch(time: t, from: from, to: to, latency: latency)
    }

    func testBounceDefinition() {
        let pair = [sw(10, 1, 2), sw(12, 2, 1)]
        XCTAssertEqual(SwitchMetrics.tally(pair, keys: [], clicks: []).bounces, 1)
        XCTAssertEqual(SwitchMetrics.tally([sw(10, 1, 2), sw(13.5, 2, 1)], keys: [], clicks: []).bounces, 0, "more than 3 s")
        XCTAssertEqual(SwitchMetrics.tally(pair, keys: [.init(time: 11, window: 2)], clicks: []).bounces, 0, "typed in B")
        XCTAssertEqual(SwitchMetrics.tally(pair, keys: [], clicks: [(11, 2)]).bounces, 0, "clicked in B")
        XCTAssertEqual(SwitchMetrics.tally(pair, keys: [], clicks: [(11, 3)]).bounces, 1, "a click elsewhere doesn't count")
        XCTAssertEqual(SwitchMetrics.tally([sw(10, 1, 2), sw(12, 2, 3)], keys: [], clicks: []).bounces, 0, "on to C isn't back")
    }

    func testTypingAndLateDefinitions() {
        let keysAround = [SwitchMetrics.Key(time: 9.2, window: 1), .init(time: 10.8, window: 2)]
        XCTAssertEqual(SwitchMetrics.tally([sw(10, 1, 2, latency: 0.3)], keys: keysAround, clicks: []).typing, 1)
        XCTAssertEqual(SwitchMetrics.tally([sw(10, 1, 2, latency: 0.3)], keys: [.init(time: 8, window: 1), .init(time: 10.8, window: 2)],
                                           clicks: []).typing, 0, "no key in the 1.5 s before")
        // Already typing into B (live put focus there): catching up isn't interrupting.
        XCTAssertEqual(SwitchMetrics.tally([sw(10, 1, 2, latency: 0.3)], keys: [.init(time: 9.2, window: 2), .init(time: 10.8, window: 2)],
                                           clicks: []).typing, 0)
        // A key between settling on B and the switch went to the old window: late, not typing.
        let late = SwitchMetrics.tally([sw(10, 1, 2, latency: 0.5)], keys: [.init(time: 9.7, window: 1), .init(time: 10.2, window: 2)], clicks: [])
        XCTAssertEqual(late.late, 1)
        XCTAssertEqual(late.typing, 0)
    }

    func testMissedSwitchAndLatency() {
        var m = SwitchMetrics()
        for i in 0..<100 { m.sampled(at: Double(i) * 0.02, dt: 0.02, hovered: 2, speed: 2) }
        m.explicitFocus(at: 2.0, to: 2, current: 1)
        XCTAssertEqual(m.missed, 1, "head on B for 2 s, the user clicked B")
        m.explicitFocus(at: 2.0, to: 2, current: 2)
        m.explicitFocus(at: 2.0, to: 3, current: 1)
        XCTAssertEqual(m.missed, 1)
        m.sampled(at: 2.02, dt: 0.02, hovered: 3, speed: 60)
        m.sampled(at: 2.1, dt: 0.02, hovered: 3, speed: 10)
        m.switched(at: 2.4, from: 1, to: 3)
        XCTAssertEqual(m.switches.last?.latency ?? 0, 0.38, accuracy: 1e-9, "from the last fast sample on C")
        XCTAssertEqual(m.seconds, 2.04, accuracy: 1e-9)
    }

    func testMatchingIsOneToOne() {
        let a = [sw(10, 1, 2), sw(20, 2, 1), sw(30, 1, 3)]
        let b = [sw(10.4, 1, 2), sw(10.6, 1, 2), sw(25, 2, 1), sw(31, 1, 3)]
        XCTAssertEqual(SwitchMetrics.matched(a, b), 2)
        XCTAssertEqual(SwitchMetrics.matched(b, a), 2)
    }
}
