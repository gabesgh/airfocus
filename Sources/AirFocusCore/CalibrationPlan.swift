import CoreGraphics
import Foundation

/// One dot the user points at during calibration.
public struct CalibrationPoint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case window(CGWindowID)
        case screen(index: Int, role: ScreenRole)
    }

    public enum ScreenRole: String, Sendable { case centre, topLeft, topRight, bottomLeft, bottomRight }

    public var kind: Kind
    public var pointCG: CGPoint

    public init(kind: Kind, pointCG: CGPoint) { self.kind = kind; self.pointCG = pointCG }

    public var windowID: CGWindowID? {
        if case .window(let id) = kind { return id }
        return nil
    }
}

/// Calibration point generation (spec §2.3): every tracked window's visible centre, plus
/// supplementary screen points when the windows alone would give a poorly conditioned fit.
public enum CalibrationPlan {
    public static let maxPoints = 12
    public static let minWindows = 3
    public static let collinearFraction: CGFloat = 0.15   // spread under 15% of the screen extent
    public static let supplementInset: CGFloat = 0.15     // corners inset 15%
    public static let duplicateRadius = 60.0              // skip a supplement this close to another dot
    public static let columnGap: CGFloat = 40             // ordering: dots within 40 pt share a column

    public struct Reasons: Equatable, Sendable {
        public var fewWindows = false
        public var collinearX = false
        public var collinearY = false
        public var emptyScreens: [Int] = []
        public var any: Bool { fewWindows || collinearX || collinearY || !emptyScreens.isEmpty }
        public init() {}
    }

    public struct Result: Equatable, Sendable {
        public var points: [CalibrationPoint]
        public var reasons: Reasons
    }

    /// `windows` are (id, dot) pairs in CG space; `screensCG` are the display frames in CG space.
    public static func make(windows: [(id: CGWindowID, dot: CGPoint)], screensCG: [CGRect]) -> Result {
        var reasons = Reasons()
        let dots = windows.map(\.dot)
        reasons.fewWindows = windows.count < minWindows
        let extent = Geometry.union(screensCG)
        if dots.count >= 2, !extent.isNull {
            let xs = dots.map(\.x), ys = dots.map(\.y)
            reasons.collinearX = (xs.max()! - xs.min()!) < collinearFraction * extent.width
            reasons.collinearY = (ys.max()! - ys.min()!) < collinearFraction * extent.height
        } else if dots.count < 2 {
            reasons.collinearX = true; reasons.collinearY = true
        }
        for (i, s) in screensCG.enumerated() where !dots.contains(where: { s.contains($0) }) {
            reasons.emptyScreens.append(i)
        }

        let needAll = reasons.fewWindows || reasons.collinearX || reasons.collinearY
        let supplementScreens = screensCG.indices.filter { needAll || reasons.emptyScreens.contains($0) }

        // Centres first so that, if the cap bites, every screen keeps at least its centre.
        var supplements: [CalibrationPoint] = []
        let roles: [CalibrationPoint.ScreenRole] = [.centre, .topLeft, .topRight, .bottomLeft, .bottomRight]
        for role in roles {
            for i in supplementScreens {
                let p = screenPoint(screensCG[i], role)
                let taken = dots + supplements.map(\.pointCG)
                guard !taken.contains(where: { Geometry.distance($0, p) < duplicateRadius }) else { continue }
                supplements.append(CalibrationPoint(kind: .screen(index: i, role: role), pointCG: p))
            }
        }
        if supplements.count > maxPoints { supplements = Array(supplements.prefix(maxPoints)) }

        var windowPoints = order(windows.map { CalibrationPoint(kind: .window($0.id), pointCG: $0.dot) })
        let budget = maxPoints - supplements.count
        if windowPoints.count > budget { windowPoints = evenlySubsample(windowPoints, count: budget) }

        return Result(points: order(windowPoints + supplements), reasons: reasons)
    }

    static func screenPoint(_ s: CGRect, _ role: CalibrationPoint.ScreenRole) -> CGPoint {
        let dx = s.width * supplementInset, dy = s.height * supplementInset
        switch role {
        case .centre: return CGPoint(x: s.midX, y: s.midY)
        case .topLeft: return CGPoint(x: s.minX + dx, y: s.minY + dy)
        case .topRight: return CGPoint(x: s.maxX - dx, y: s.minY + dy)
        case .bottomLeft: return CGPoint(x: s.minX + dx, y: s.maxY - dy)
        case .bottomRight: return CGPoint(x: s.maxX - dx, y: s.maxY - dy)
        }
    }

    /// Left to right, then top to bottom: dots are grouped into columns (a new column starts when
    /// x jumps by more than `columnGap`), and each column is read top to bottom.
    public static func order(_ points: [CalibrationPoint]) -> [CalibrationPoint] {
        let byX = points.sorted { ($0.pointCG.x, $0.pointCG.y) < ($1.pointCG.x, $1.pointCG.y) }
        var columns: [[CalibrationPoint]] = []
        var lastX: CGFloat?
        for p in byX {
            if let lx = lastX, p.pointCG.x - lx <= columnGap {
                columns[columns.count - 1].append(p)
            } else {
                columns.append([p])
            }
            lastX = p.pointCG.x
        }
        return columns.flatMap { $0.sorted { $0.pointCG.y < $1.pointCG.y } }
    }

    static func evenlySubsample<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0 else { return [] }
        guard items.count > count else { return items }
        if count == 1 { return [items[items.count / 2]] }
        return (0..<count).map { i in items[Int((Double(i) * Double(items.count - 1) / Double(count - 1)).rounded())] }
    }
}
