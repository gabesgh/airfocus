import AppKit
import AirFocusCore

/// Trace files on disk (spec §2.10): one per tracking session, split at each hour, gzipped once
/// closed, kept 14 days and 500 MB at most, oldest first. Everything here runs on its own utility
/// queue, so nothing touches the disk on the main thread's sample path.
final class TraceWriter: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AirFocus/Traces", isDirectory: true)
    static let maxTotalBytes: Int64 = 500 * 1024 * 1024
    static let retention: TimeInterval = 14 * 24 * 3600

    private let queue = DispatchQueue(label: "com.gshimoon.airfocus.trace", qos: .utility)
    // Only touched on `queue`.
    private var handle: FileHandle?
    private var openURL: URL?

    func open(name: String) {
        queue.async { [self] in
            closeHandle()
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let url = Self.directory.appendingPathComponent(name)
                guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                handle = try FileHandle(forWritingTo: url)
                openURL = url
            } catch {
                Log.error(.app, "session trace: cannot create \(name): \(error.localizedDescription)")
            }
        }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard let h = handle else { return }
            do { try h.write(contentsOf: data) } catch {
                Log.error(.app, "session trace: write failed: \(error.localizedDescription)")
                closeHandle()
            }
        }
    }

    /// Closes the open file, compresses it unless `compress` is off (at quit, the next launch does),
    /// then applies retention and the size cap.
    func close(compress: Bool) {
        queue.async { [self] in
            let url = openURL
            closeHandle()
            if compress, let url { Self.gzip(url) }
            sweep()
        }
    }

    /// Blocks until everything queued is on disk (quit).
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// At launch: compress files a crash or quit left plain, and apply retention and the cap. A file
    /// touched in the last 10 minutes is left alone: another copy of the app may still be writing it.
    func tidy() {
        queue.async { [self] in
            let fm = FileManager.default
            for url in Self.files() where url.pathExtension == TraceFormat.fileExtension && url != openURL {
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                if Date().timeIntervalSince(modified) > 600 { Self.gzip(url) }
            }
            sweep()
        }
    }

    /// Deletes every trace, the open one included (recording reopens a fresh file itself).
    func deleteAll(then done: @escaping @Sendable (Int) -> Void) {
        queue.async { [self] in
            closeHandle()
            var n = 0
            for url in Self.files() where (try? FileManager.default.removeItem(at: url)) != nil { n += 1 }
            DispatchQueue.main.async { done(n) }
        }
    }

    private func closeHandle() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        openURL = nil
    }

    private static func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix("." + TraceFormat.fileExtension) || $0.hasSuffix("." + TraceFormat.fileExtension + ".gz") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// `x.aftrace` → `x.aftrace.gz`, checked by decompressing before the original goes.
    private static func gzip(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let gz = Gzip.compress(data), Gzip.decompress(gz) == data else {
            Log.error(.app, "session trace: could not compress \(url.lastPathComponent); keeping it plain")
            return
        }
        let out = url.appendingPathExtension("gz")
        do {
            try gz.write(to: out, options: .atomic)
            try FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: out)
        }
    }

    /// Oldest first: anything past 14 days, then until the rest fits in 500 MB. The open file stays.
    private func sweep() {
        let fm = FileManager.default
        let now = Date()
        var entries: [(url: URL, date: Date, size: Int64)] = Self.files().compactMap { url in
            guard url != openURL, let a = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return (url, a[.modificationDate] as? Date ?? now, (a[.size] as? NSNumber)?.int64Value ?? 0)
        }
        entries.sort { $0.date < $1.date }
        var removed = 0
        entries.removeAll { e in
            guard now.timeIntervalSince(e.date) > Self.retention else { return false }
            if (try? fm.removeItem(at: e.url)) != nil { removed += 1 }
            return true
        }
        let openSize = openURL.flatMap { (try? fm.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber }?.int64Value ?? 0
        var total = entries.reduce(openSize) { $0 + $1.size }
        for e in entries where total > Self.maxTotalBytes {
            if (try? fm.removeItem(at: e.url)) != nil { removed += 1; total -= e.size }
        }
        if removed > 0 { Log.info(.app, "session trace: removed \(removed) old file(s) (14 days, 500 MB)") }
    }
}

/// The live side of session traces and of the intent engine's shadow mode (spec §2.10, §2.11).
/// AppController emits events as things happen; while tracking, each one goes to the shadow intent
/// engine and, if Record Session Trace is on, into the file. Lines are buffered and handed to the
/// writer every few seconds, so the 50 Hz sample path only formats a line.
@MainActor
final class SessionTrace {
    static let flushInterval: TimeInterval = 3

    /// Builds the header for part `n` of the session, plus a snapshot so the part replays on its own.
    var makeHeader: ((_ session: String, _ part: Int) -> (TraceHeader, [TraceEvent]))?
    /// App names for the `[intent]` log lines, by window id.
    var appName: ((CGWindowID) -> String?)?

    let launch = "\(ProcessInfo.processInfo.processIdentifier)-\(Int(ProcessInfo.processInfo.systemUptime))"
    private let writer = TraceWriter()
    private(set) var active = false
    private(set) var recording = false
    private var buffer = Data()
    private var lastFlush: TimeInterval = 0
    private var session = ""
    private var part = 0
    private var partHour = -1
    private var runner = IntentRunner(summaries: true)

    // Only what changed goes in.
    private var lastWindows: [TraceWindow]?
    private var lastFront: CGWindowID??
    private var lastReject: TargetSelector.Reject??
    private var lastConfig: LiveConfig?
    private(set) var lastKey: TimeInterval = -.infinity

    /// Once at launch, after the check that no other copy is running.
    func tidy() { writer.tidy() }

    static func fileName(session: String, part: Int) -> String {
        "\(session)-p\(part).\(TraceFormat.fileExtension)"
    }

    /// Tracking started. `record`: write a file as well as running the shadow engine.
    func begin(at t: TimeInterval, record: Bool) {
        guard !active else { return }
        active = true
        lastWindows = nil
        lastFront = nil
        lastReject = nil
        lastConfig = nil
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"     // stop and start within a second must not reuse a name
        session = f.string(from: Date())
        part = 0
        if record { startRecording() }
        emit(.tracking(t, true))
    }

    /// Tracking stopped. `quitting`: leave compression to the next launch so quit stays quick.
    func end(at t: TimeInterval, quitting: Bool = false) {
        guard active else { return }
        emit(.tracking(t, false))
        stopRecording(at: t, compress: !quitting)
        if quitting { writer.flush() }
        active = false
    }

    /// Record Session Trace turned on or off while tracking.
    func setRecording(_ on: Bool, at t: TimeInterval) {
        guard active, on != recording else { return }
        if on { startRecording() } else { stopRecording(at: t, compress: true) }
    }

    private func startRecording() {
        part += 1
        partHour = Calendar.current.component(.hour, from: Date())
        recording = true
        writer.open(name: Self.fileName(session: session, part: part))
        buffer.append(Data((TraceFormat.banner + "\n").utf8))
        if let (header, snapshot) = makeHeader?(session, part) {
            write(.header(header))
            if part > 1 { snapshot.forEach(write) }
        }
        lastFlush = ProcessInfo.processInfo.systemUptime
        Log.info(.app, "session trace: recording \(Self.fileName(session: session, part: part))")
    }

    private func stopRecording(at t: TimeInterval, compress: Bool) {
        guard recording else { return }
        write(.end(t))
        flush()
        writer.close(compress: compress)
        recording = false
    }

    /// The 1 Hz housekeeping tick: flush, and start a new part on the hour.
    func tick() {
        guard active, recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if Calendar.current.component(.hour, from: Date()) != partHour {
            stopRecording(at: now, compress: true)
            startRecording()
        } else if now - lastFlush >= Self.flushInterval {
            flush()
        }
    }

    private func flush() {
        lastFlush = ProcessInfo.processInfo.systemUptime
        guard !buffer.isEmpty else { return }
        writer.append(buffer)
        buffer = Data()
    }

    private func write(_ e: TraceEvent) {
        buffer.append(Data((e.line + "\n").utf8))
    }

    // MARK: Events

    func emit(_ e: TraceEvent) {
        guard active else { return }
        if recording {
            write(e)
            if e.time - lastFlush >= Self.flushInterval { flush() }
        }
        for out in runner.consume(e) { shadow(out, after: e) }
    }

    /// Only when the window list changed.
    func windows(_ ws: [TrackedWindow], at t: TimeInterval) {
        guard active else { return }
        let traced = ws.map(TraceWindow.init)
        guard traced != lastWindows else { return }
        lastWindows = traced
        emit(.windows(t, traced))
    }

    /// A front change, with who made it.
    func front(_ id: CGWindowID?, at t: TimeInterval, ours: Bool) {
        guard active, lastFront != .some(id) else { return }
        let first = lastFront == nil
        lastFront = .some(id)
        if !first { emit(.front(t, id, ours ? .request : .external)) }
    }

    func reject(_ r: TargetSelector.Reject?, at t: TimeInterval) {
        guard active, lastReject != .some(r) else { return }
        lastReject = .some(r)
        emit(.reject(t, r))
    }

    func config(_ c: LiveConfig, at t: TimeInterval) {
        guard active, c != lastConfig else { return }
        lastConfig = c
        emit(.config(t, c))
    }

    /// A key-down, from the monitor or noticed through CGEventSource. One line per key.
    func key(at t: TimeInterval) {
        guard active, t > lastKey + 0.05 else { return }
        lastKey = t
        emit(.key(t))
    }

    // MARK: Shadow intent

    private func shadow(_ out: IntentRunner.Output, after e: TraceEvent) {
        switch out {
        case .wouldSwitch(let t, _, let to, let evidence, let threshold, let phase, let typing, let liveFront, let agrees):
            if recording { write(.intent(t, to, evidence: evidence, threshold: threshold)) }
            let name = { (id: CGWindowID) in "\(self.appName?(id) ?? "window") wid \(id)" }
            let live = agrees ? "live agrees" : "live stays on \(liveFront.map(name) ?? "no window")"
            Log.info(.intent, String(format: "would switch to %@ (%@, evidence %.1f of %.1f%@) · %@", name(to), phase.rawValue,
                                     evidence, threshold, typing ? ", typing" : "", live))
        case .note(_, .clickAnchoredYaw(let residual)):
            Log.info(.intent, String(format: "a click anchored yaw (pitch residual %.1f°): this could stand in for ⌃⌥⌘R", residual))
        case .note(_, .typingAnchoredYaw):
            Log.info(.intent, "typing anchored yaw")
        case .note(_, .clickRejected(let residual)):
            Log.debug(.intent, String(format: "click ignored: %.1f° from where the head pointed", residual))
        case .note(_, .clickMeasured):
            break
        case .summary(let line):
            Log.info(.intent, line)
        }
    }

    // MARK: Menu

    static func reveal() {
        try? FileManager.default.createDirectory(at: TraceWriter.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([TraceWriter.directory])
    }

    /// Deletes every trace; a session being recorded carries on in a fresh file.
    func deleteAll() {
        let wasRecording = active && recording
        if wasRecording {
            buffer.removeAll()
            recording = false
        }
        writer.deleteAll { [weak self] n in
            MainActor.assumeIsolated {
                Log.info(.app, "session trace: deleted \(n) file(s)")
                guard let self, wasRecording, self.active, !self.recording else { return }
                self.startRecording()
            }
        }
    }
}
