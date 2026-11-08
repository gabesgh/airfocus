import CoreGraphics
import Foundation

/// A focusable on-screen window of another app, after filtering and occlusion (R§3.3, R§3.5).
public struct TrackedWindow: Equatable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let bundleID: String?
    public let frameCG: CGRect           // global, top-left origin (CG / AX space)
    public var visibleRects: [CGRect]    // disjoint pieces not covered by windows in front, clipped to screens
    public var visibleFraction: Double   // visible area / frame area
    public var targetPointCG: CGPoint    // where the dot goes: inside the visible part

    public init(id: CGWindowID, pid: pid_t, appName: String, bundleID: String?, frameCG: CGRect,
                visibleRects: [CGRect], visibleFraction: Double, targetPointCG: CGPoint) {
        self.id = id; self.pid = pid; self.appName = appName; self.bundleID = bundleID
        self.frameCG = frameCG; self.visibleRects = visibleRects
        self.visibleFraction = visibleFraction; self.targetPointCG = targetPointCG
    }

    /// Convenience for tests and previews: a fully visible window.
    public init(id: CGWindowID, pid: pid_t = 1, appName: String = "App", frameCG: CGRect) {
        self.init(id: id, pid: pid, appName: appName, bundleID: nil, frameCG: frameCG,
                  visibleRects: [frameCG], visibleFraction: 1,
                  targetPointCG: CGPoint(x: frameCG.midX, y: frameCG.midY))
    }

    public func visibleContains(_ p: CGPoint) -> Bool {
        visibleRects.contains { $0.contains(p) }
    }

    /// Hit test with every visible piece grown by `margin` points (used for hysteresis).
    public func visibleContains(_ p: CGPoint, grownBy margin: CGFloat) -> Bool {
        visibleRects.contains { $0.insetBy(dx: -margin, dy: -margin).contains(p) }
    }
}

public enum WindowRejection: String, CaseIterable, Sendable {
    case malformed = "malformed entry"
    case notNormalLayer = "layer ≠ 0 (menu bar, Dock, overlays)"
    case ownProcess = "own window"
    case transparent = "alpha ≤ 0.05"
    case ignoredOwner = "system owner (Stage Manager, Dock, Control Center)"
    case tooSmall = "smaller than 160×100"
    case offScreen = "under 90% on screen (Stage Manager strip, parked)"
    case occluded = "under 15% visible"
}

public struct WindowFilterResult: Sendable {
    public var windows: [TrackedWindow]
    public var rejections: [WindowRejection: Int]
    public var rawCount: Int
    public var missionControlOpen = false
}

public enum WindowFilter {
    public static let minSize = CGSize(width: 160, height: 100)
    public static let minAlpha = 0.05
    public static let minOnScreenFraction = 0.9
    public static let minVisibleFraction = 0.15
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.WindowManager", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
    ]
    /// Own windows that paint over other apps while Settings is open: its window (layer 0) and the
    /// colour panel (floating, layer 3). Stops below the status bar (25), so the status item, our
    /// menus and the screen-saver-level overlay panels never count.
    public static let ownOccluderLayers = 0..<25
    /// The Dock puts a full-screen window on this layer only while Mission Control is open (checked on 26.7.1).
    public static let missionControlLayer = 18

    public struct AppInfo: Sendable {
        public var bundleID: String?
        public var name: String?
        public init(bundleID: String?, name: String?) { self.bundleID = bundleID; self.name = name }
    }

    /// Filters a front-to-back `CGWindowListCopyWindowInfo` result into tracked windows.
    /// `appInfo` resolves a PID to its bundle id and name (NSRunningApplication in the app):
    /// kCGWindowOwnerName may be nil on macOS 26 without Screen Recording (R§3.2).
    /// `ownWindowsOcclude`: our own windows are never tracked either way; while Settings is open
    /// they also count as covering what's behind them, so no dot lands on them.
    public static func filter(_ raw: [[String: Any]], ownPID: pid_t, screensCG: [CGRect],
                              ownWindowsOcclude: Bool = false,
                              appInfo: (pid_t) -> AppInfo?) -> WindowFilterResult {
        var result: [TrackedWindow] = []
        var rejections: [WindowRejection: Int] = [:]
        var occluders: [CGRect] = []          // frames of normal windows already seen (they are in front)
        var infoCache: [pid_t: AppInfo?] = [:]
        var missionControlOpen = false
        func cachedInfo(_ pid: pid_t) -> AppInfo? {
            if let cached = infoCache[pid] { return cached }
            let app = appInfo(pid)
            infoCache[pid] = app
            return app
        }
        func reject(_ r: WindowRejection) { rejections[r, default: 0] += 1 }

        for info in raw {
            guard let idNum = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layerNum = info[kCGWindowLayer as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { reject(.malformed); continue }
            let id = CGWindowID(idNum.uint32Value)
            let pid = pid_t(pidNum.int32Value)
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1

            if ownWindowsOcclude, pid == ownPID, ownOccluderLayers.contains(layerNum.intValue), alpha > minAlpha {
                occluders.append(frame)
            }

            if layerNum.intValue == missionControlLayer, cachedInfo(pid)?.bundleID == "com.apple.dock",
               screensCG.contains(where: { Geometry.area(frame.intersection($0)) >= minOnScreenFraction * Geometry.area($0) }) {
                missionControlOpen = true
            }

            // 1. Normal windows only: drops menu bar, Dock, status items, notification centre and
            //    screensaver-level overlays (including our own panels).
            guard layerNum.intValue == 0 else { reject(.notNormalLayer); continue }
            guard pid != ownPID else { reject(.ownProcess); continue }
            guard alpha > minAlpha else { reject(.transparent); continue }

            let app = cachedInfo(pid)
            if let bid = app?.bundleID, ignoredBundleIDs.contains(bid) { reject(.ignoredOwner); continue }

            // Everything below is a real window that paints over whatever is behind it.
            defer { occluders.append(frame) }
            guard frame.width >= minSize.width, frame.height >= minSize.height else { reject(.tooSmall); continue }

            // Stage Manager strip thumbnails and parked windows sit (partly) off every screen.
            let onScreen = screensCG.map { frame.intersection($0) }.filter { !$0.isNull && !$0.isEmpty }
            let onScreenArea = onScreen.reduce(0.0) { $0 + Geometry.area($1) }
            let frameArea = Geometry.area(frame)
            guard frameArea > 0, onScreenArea >= minOnScreenFraction * frameArea else { reject(.offScreen); continue }

            let pieces = onScreen.flatMap { Geometry.visibleRegion(of: $0, occludedBy: occluders) }
            let fraction = pieces.reduce(0.0) { $0 + Geometry.area($1) } / frameArea
            guard fraction >= minVisibleFraction, let dot = Geometry.visibleCentre(of: pieces) else {
                reject(.occluded); continue
            }
            let name = app?.name ?? (info[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)"
            result.append(TrackedWindow(id: id, pid: pid, appName: name, bundleID: app?.bundleID,
                                        frameCG: frame, visibleRects: pieces,
                                        visibleFraction: fraction, targetPointCG: dot))
        }
        return WindowFilterResult(windows: result, rejections: rejections, rawCount: raw.count,
                                  missionControlOpen: missionControlOpen)
    }

    /// Front-to-back hit test against visible regions (spec §2.4).
    public static func window(at p: CGPoint, in windows: [TrackedWindow]) -> TrackedWindow? {
        windows.first { $0.visibleContains(p) }
    }
}
