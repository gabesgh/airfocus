import CoreGraphics
import Foundation

/// Holding the head pointer on a Mission Control thumbnail picks it (spec §2.9). Pure: the
/// controller feeds it the pointer and the thumbnails' frames, and presses what it picks.
public struct ThumbnailPicker: Sendable {
    public struct Config: Sendable {
        public var dwell: TimeInterval = 0.9          // twice a switch: a pick ends Mission Control
        public var maxSpeed = 25.0                    // °/s: time only counts with the head settled
        public var slipMargin: CGFloat = 30           // points the pointer can slip off the thumbnail
        public var openSettle: TimeInterval = 0.5     // the opening animation, and the head coming back from a flick
        public var inputHold: TimeInterval = 0.5      // someone using the mouse is picking by hand
        public var frameTolerance: CGFloat = 4        // the same thumbnail, between reads of its frame
        public var maxStep: TimeInterval = 0.1        // a gap in the samples doesn't count as holding

        public init() {}
    }

    public struct Decision: Equatable, Sendable {
        /// Index into the frames passed in, and how far along the hold is (0...1).
        public var candidate: Int?
        public var progress: Double?
        public var pick = false

        public init(candidate: Int? = nil, progress: Double? = nil, pick: Bool = false) {
            self.candidate = candidate; self.progress = progress; self.pick = pick
        }
    }

    public var config: Config
    private var openedAt: TimeInterval = -.infinity
    private var candidateFrame: CGRect?
    private var held: TimeInterval = 0
    private var lastUpdate: TimeInterval?
    private var picked = false

    public init(config: Config = Config()) { self.config = config }

    /// Mission Control just opened.
    public mutating func begin(at now: TimeInterval) {
        openedAt = now
        candidateFrame = nil
        held = 0
        lastUpdate = nil
        picked = false
    }

    public mutating func update(point: CGPoint, frames: [CGRect], speed: Double, inputIdle: TimeInterval,
                                now: TimeInterval) -> Decision {
        let step = min(lastUpdate.map { now - $0 } ?? 0, config.maxStep)
        lastUpdate = now
        guard !picked, now - openedAt >= config.openSettle else { return Decision() }
        guard let index = candidate(for: point, in: frames) else {
            candidateFrame = nil
            held = 0
            return Decision()
        }
        if !isCandidate(frames[index]) {
            candidateFrame = frames[index]     // a new target, or the thumbnail is still animating
            held = 0
        }
        if inputIdle < config.inputHold {
            held = 0
        } else if speed < config.maxSpeed {
            held += step
        }
        guard held >= config.dwell else {
            return Decision(candidate: index, progress: held / max(config.dwell, 1e-3))
        }
        picked = true
        return Decision(candidate: index, progress: 1, pick: true)
    }

    private func isCandidate(_ frame: CGRect) -> Bool {
        guard let c = candidateFrame else { return false }
        let t = config.frameTolerance
        return abs(c.minX - frame.minX) <= t && abs(c.minY - frame.minY) <= t
            && abs(c.width - frame.width) <= t && abs(c.height - frame.height) <= t
    }

    /// The current candidate while the pointer stays near it, else the thumbnail under the pointer.
    /// Their frames can overlap, so the one whose centre is nearest wins.
    private func candidate(for p: CGPoint, in frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: isCandidate),
           frames[i].insetBy(dx: -config.slipMargin, dy: -config.slipMargin).contains(p) {
            return i
        }
        return frames.indices.filter { frames[$0].contains(p) }.min {
            Geometry.distance(p, CGPoint(x: frames[$0].midX, y: frames[$0].midY))
                < Geometry.distance(p, CGPoint(x: frames[$1].midX, y: frames[$1].midY))
        }
    }
}
