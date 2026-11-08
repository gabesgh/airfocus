import Foundation
import os

/// State-change logging to os.Logger and to ~/Library/Logs/AirFocus/AirFocus.log
/// (rotated at 5 MB). Never log keystrokes or window titles: app names and window ids only.
enum Log {
    static let subsystem = "com.gshimoon.airfocus"

    enum Category: String, CaseIterable {
        case app, motion, windows, focus, calibration, lookAway, session, hotkeys, gesture, intent
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AirFocus", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("AirFocus.log")
    static let maxBytes: UInt64 = 5 * 1024 * 1024

    /// CLI modes print to stdout instead and leave the log file alone.
    nonisolated(unsafe) static var fileLoggingEnabled = true

    private static let loggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })
    private static let queue = DispatchQueue(label: "com.gshimoon.airfocus.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var bytesWritten: UInt64 = 0
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ category: Category, _ message: String) { write(category, message, level: .info) }
    static func error(_ category: Category, _ message: String) { write(category, message, level: .error) }
    static func debug(_ category: Category, _ message: String) { loggers[category]?.debug("\(message, privacy: .public)") }

    private static func write(_ category: Category, _ message: String, level: OSLogType) {
        loggers[category]?.log(level: level, "\(message, privacy: .public)")
        guard fileLoggingEnabled else { return }
        let date = Date()
        queue.async {
            let tag = level == .error ? "ERROR " : ""
            let line = "\(stamp.string(from: date)) [\(category.rawValue)] \(tag)\(message)\n"
            append(Data(line.utf8))
        }
    }

    /// Runs on `queue`.
    private static func append(_ data: Data) {
        if handle == nil { open() }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
            bytesWritten += UInt64(data.count)
        } catch {
            handle = nil
            return
        }
        if bytesWritten > maxBytes { rotate() }
    }

    private static func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
        bytesWritten = (try? h.seekToEnd()) ?? 0
        handle = h
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let old = directory.appendingPathComponent("AirFocus.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        open()
    }

    /// Blocks until queued lines are on disk (used before exit).
    static func flush() { queue.sync {} }
}
