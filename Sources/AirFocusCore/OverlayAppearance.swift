import Foundation

/// A user-chosen overlay colour: sRGB doubles, or "follow the system accent colour". Foundation
/// only; the app resolves it to a CGColor. Components are always in range and the alpha is high
/// enough to see, whatever the source (a wide-gamut colour panel can hand back values outside 0...1).
public struct StyleColor: Equatable, Sendable {
    /// Below this a dot or border would be invisible, so it never gets stored or drawn.
    public static let minimumAlpha = 0.25
    private static let accentToken = "accent"

    public let followsAccent: Bool
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public static let accent = StyleColor(followsAccent: true, red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = StyleColor(red: 1, green: 1, blue: 1)

    private init(followsAccent: Bool, red: Double, green: Double, blue: Double, alpha: Double) {
        self.followsAccent = followsAccent
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func unit(_ v: Double) -> Double { v.isNaN ? 0 : min(1, max(0, v)) }
        self.init(followsAccent: false, red: unit(red), green: unit(green), blue: unit(blue),
                  alpha: alpha.isNaN ? 1 : min(1, max(Self.minimumAlpha, alpha)))
    }

    /// "accent", or "r g b a" with full precision so a stored colour round-trips exactly.
    public var storageString: String {
        followsAccent ? Self.accentToken : "\(red) \(green) \(blue) \(alpha)"
    }

    /// Nil for anything malformed, out of range or too transparent: the caller uses its default.
    public init?(storageString s: String) {
        if s == Self.accentToken { self = .accent; return }
        let parts = s.split(separator: " ").map { Double($0) }
        guard parts.count == 4 else { return nil }
        let v = parts.compactMap { $0 }
        guard v.count == 4, v.allSatisfy({ $0.isFinite }),
              v[0...2].allSatisfy({ (0...1).contains($0) }), (Self.minimumAlpha...1).contains(v[3]) else { return nil }
        self.init(red: v[0], green: v[1], blue: v[2], alpha: v[3])
    }

    /// "#RRGGBB" or "accent", for the CLI's --style option.
    public init?(hexOrAccent s: String) {
        if s == Self.accentToken { self = .accent; return }
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((n >> 16) & 0xFF) / 255, green: Double((n >> 8) & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
    }

    /// WCAG relative luminance of an sRGB colour, 0 (black) to 1 (white).
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The dark rim that keeps a light dot visible on a white window would vanish, along with the
    /// dot, on a dark one when the fill is itself dark. Such a fill gets a light rim instead.
    public static func needsLightRim(red: Double, green: Double, blue: Double) -> Bool {
        luminance(red: red, green: green, blue: blue) < 0.18
    }
}

/// What the head pointer looks like.
public enum PointerShape: String, CaseIterable, Sendable {
    case circle, ring, dot, crosshair

    public var title: String {
        switch self {
        case .circle: return "Circle"
        case .ring: return "Ring"
        case .dot: return "Dot"
        case .crosshair: return "Crosshair"
        }
    }
}

/// How the runtime overlay looks. Calibration ignores the toggles and sizes: it always shows its
/// own dots, ring and banners. The defaults are the app's original look (spec §2.2).
public struct OverlayAppearance: Equatable, Sendable {
    public var showDots = true
    public var dotColor = StyleColor.white
    public var dotSize = SettingsDefault.dotSize
    public var showBorder = true
    public var borderColor = StyleColor.accent
    public var borderWidth = SettingsDefault.borderWidth
    public var showPointer = true
    public var pointerColor = StyleColor.accent
    public var pointerShape = SettingsDefault.pointerShape
    public var pointerSize = SettingsDefault.pointerSize
    public var showRing = true
    public var showBanners = true

    public init() {}

    /// The pending-candidate border is thinner than the focused one, in today's proportion (2.5 : 4).
    public var pendingBorderWidth: Double { borderWidth * 0.625 }
    /// The progress ring keeps today's 6 pt clearance around the dot, so a bigger dot can't hide it.
    public var ringRadius: Double { dotSize / 2 + 6 }
    /// Thinner on a smaller pointer, up to the original 2.5 pt at the default size.
    public var pointerLineWidth: Double { min(2.5, max(1.5, pointerSize * 0.1)) }
}
