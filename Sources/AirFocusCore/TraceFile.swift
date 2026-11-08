import Foundation

/// Gzip for closed trace files: Foundation's zlib (raw DEFLATE) inside the standard gzip wrapper,
/// so `zcat`, `zgrep` and `gunzip` read them too. Single member, no extra fields when writing.
public enum Gzip {
    public static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])     // magic, deflate, no flags, no mtime, Unix
        out.append(deflated)
        append32(crc32(data), to: &out)
        append32(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    /// Nil for anything that isn't intact gzip.
    public static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i <= b.count - 8,
              let raw = try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let tail = b.count - 8
        let crc = UInt32(b[tail]) | UInt32(b[tail + 1]) << 8 | UInt32(b[tail + 2]) << 16 | UInt32(b[tail + 3]) << 24
        let size = UInt32(b[tail + 4]) | UInt32(b[tail + 5]) << 8 | UInt32(b[tail + 6]) << 16 | UInt32(b[tail + 7]) << 24
        guard crc == crc32(raw), size == UInt32(truncatingIfNeeded: raw.count) else { return nil }
        return raw
    }

    public static func isGzip(_ data: Data) -> Bool { data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for byte in p { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func append32(_ v: UInt32, to d: inout Data) {
        d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }
}

/// Reading traces from disk for a replay: plain `.aftrace`, or gzipped `.aftrace.gz`.
public enum TraceFile {
    /// The trace files at `path` (a file, or every trace in a directory), in name order, which is
    /// time order for the recorder's names.
    public static func list(_ path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [url] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.hasSuffix("." + TraceFormat.fileExtension) || $0.hasSuffix("." + TraceFormat.fileExtension + ".gz") }
            .sorted()
            .map { url.appendingPathComponent($0) }
    }

    public static func read(_ url: URL) -> (events: [TraceEvent], skipped: Int)? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        if Gzip.isGzip(data) {
            guard let raw = Gzip.decompress(data) else { return nil }
            data = raw
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return TraceEvent.parse(text)
    }
}
