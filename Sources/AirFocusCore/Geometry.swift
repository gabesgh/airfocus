import CoreGraphics
import Foundation

// Two global coordinate spaces are in play (R§3.4):
//  - CG / AX space: origin at the top-left of the primary display, y grows downwards.
//    CGWindowList bounds, AX positions and everything in Core use this space.
//  - AppKit space: origin at the bottom-left of the primary display, y grows upwards.
//    NSScreen and NSWindow frames use it.
// The primary display is NSScreen.screens[0] (the one with the menu bar), not NSScreen.main.
public enum Geometry {
    public static func cgRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func appKitRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func appKitPoint(fromCG p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    public static func cgPoint(fromAppKit p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// A CG global point in the local (bottom-left origin) coordinates of a panel whose AppKit
    /// frame origin is `panelOrigin` (overlay panels cover one screen each).
    public static func localPoint(fromCG p: CGPoint, panelOrigin: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        let a = appKitPoint(fromCG: p, primaryHeight: primaryHeight)
        return CGPoint(x: a.x - panelOrigin.x, y: a.y - panelOrigin.y)
    }

    public static func localRect(fromCG r: CGRect, panelOrigin: CGPoint, primaryHeight: CGFloat) -> CGRect {
        appKitRect(fromCG: r, primaryHeight: primaryHeight).offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
    }

    public static func area(_ r: CGRect) -> Double {
        (r.isNull || r.isEmpty) ? 0 : Double(r.width * r.height)
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    /// Distance from `p` to the nearest point of `r` (0 when inside).
    public static func distance(from p: CGPoint, to r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double(hypot(dx, dy))
    }

    /// Distance from `p` to the nearest of `rects` (0 when inside any). Infinity for no rects.
    public static func distance(from p: CGPoint, toAnyOf rects: [CGRect]) -> Double {
        rects.map { distance(from: p, to: $0) }.min() ?? .infinity
    }

    /// Bounding box of all rects (`.null` for none).
    public static func union(_ rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }

    /// `r` minus `hole`, as up to four disjoint rects (top band, bottom band, left, right).
    public static func subtract(_ hole: CGRect, from r: CGRect) -> [CGRect] {
        let i = r.intersection(hole)
        guard !i.isNull, !i.isEmpty else { return [r] }
        var out: [CGRect] = []
        if i.minY > r.minY { out.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: i.minY - r.minY)) }
        if i.maxY < r.maxY { out.append(CGRect(x: r.minX, y: i.maxY, width: r.width, height: r.maxY - i.maxY)) }
        if i.minX > r.minX { out.append(CGRect(x: r.minX, y: i.minY, width: i.minX - r.minX, height: i.height)) }
        if i.maxX < r.maxX { out.append(CGRect(x: i.maxX, y: i.minY, width: r.maxX - i.maxX, height: i.height)) }
        return out
    }

    /// The part of `r` not covered by any of `occluders`, as disjoint rects.
    public static func visibleRegion(of r: CGRect, occludedBy occluders: [CGRect]) -> [CGRect] {
        var pieces = [r]
        for o in occluders {
            guard o.intersects(r) else { continue }
            pieces = pieces.flatMap { subtract(o, from: $0) }
            if pieces.isEmpty { break }
        }
        return pieces.filter { $0.width >= 1 && $0.height >= 1 }
    }

    /// A point that lies inside the region: its area-weighted centroid when that is inside,
    /// otherwise the centre of its largest piece (an L-shaped region's centroid can fall in the hole).
    public static func visibleCentre(of pieces: [CGRect]) -> CGPoint? {
        let total = pieces.reduce(0.0) { $0 + area($1) }
        guard total > 0 else { return nil }
        let cx = pieces.reduce(0.0) { $0 + area($1) * Double($1.midX) } / total
        let cy = pieces.reduce(0.0) { $0 + area($1) * Double($1.midY) } / total
        let c = CGPoint(x: cx, y: cy)
        if pieces.contains(where: { $0.contains(c) }) { return c }
        let largest = pieces.max { area($0) < area($1) }!
        return CGPoint(x: largest.midX, y: largest.midY)
    }
}

/// The calibrated screen area expressed in head angles, degrees (R§9.4).
public struct AngleEnvelope: Codable, Equatable, Sendable {
    public var yawMin: Double
    public var yawMax: Double
    public var pitchMin: Double
    public var pitchMax: Double

    public init(yawMin: Double, yawMax: Double, pitchMin: Double, pitchMax: Double) {
        self.yawMin = yawMin; self.yawMax = yawMax; self.pitchMin = pitchMin; self.pitchMax = pitchMax
    }

    public func grown(by d: Double) -> AngleEnvelope {
        AngleEnvelope(yawMin: yawMin - d, yawMax: yawMax + d, pitchMin: pitchMin - d, pitchMax: pitchMax + d)
    }

    public func contains(yaw: Double, pitch: Double) -> Bool {
        yaw >= yawMin && yaw <= yawMax && pitch >= pitchMin && pitch <= pitchMax
    }

    public func containsPitch(_ pitch: Double) -> Bool { pitch >= pitchMin && pitch <= pitchMax }
}

/// One display as seen by the app, in CG space.
public struct DisplayInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var frameCG: CGRect

    public init(id: UInt32, vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0, frameCG: CGRect) {
        self.id = id; self.vendor = vendor; self.model = model; self.serial = serial; self.frameCG = frameCG
    }
}

/// Identifies a display arrangement so calibrations can be stored per arrangement (spec §2.3).
/// Vendor/model/serial are preferred over the CGDirectDisplayID, which can change across reboots.
public struct DisplayConfiguration: Equatable, Sendable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) { self.displays = displays }

    public var key: String {
        displays
            .map { d -> String in
                let who = (d.vendor == 0 && d.model == 0 && d.serial == 0) ? "id\(d.id)" : "\(d.vendor)-\(d.model)-\(d.serial)"
                let f = d.frameCG
                return "\(who)@\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
            }
            .sorted()
            .joined(separator: "|")
    }

    public var screensCG: [CGRect] { displays.map(\.frameCG) }
}
