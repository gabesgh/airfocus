import AppKit

/// The status item's icon: the user's AirPod-and-cursor mark (Support/MenuBarIcon.png, copied into
/// the bundle's Resources), used as a template image. Tracking is the art itself. The other states
/// leave the art whole, so the cursor stays solid: a lower opacity, or a small badge in the empty
/// corner beside the cursor, clear of it on every side.
///
/// The art is 806 px wide, so it is pre-rendered once into 1x and 2x bitmaps at the menu bar's size
/// by area-averaging its alpha, the same coverage a vector rasteriser would produce, rather than
/// left for the system to downscale on every draw. Without the resource: the old SF Symbols.
enum MenuBarIcon {
    enum Glyph: String, CaseIterable {
        case off, tracking, paused, calibrating, away

        init(_ state: AppController.IconState) {
            switch state {
            case .idle: self = .off
            case .tracking: self = .tracking
            case .paused, .problem: self = .paused
            case .calibrating: self = .calibrating
            case .away: self = .away
            }
        }

        var fallbackSymbols: [String] {
            switch self {
            case .off: return ["airpodspro", "airpods"]
            case .tracking: return ["dot.viewfinder", "airpodspro"]
            case .paused: return ["exclamationmark.triangle", "airpodspro"]
            case .calibrating: return ["scope", "dot.viewfinder"]
            case .away: return ["moon", "airpodspro"]
            }
        }
    }

    static let resourceName = "MenuBarIcon"
    /// Tall enough to hold its own next to neighbouring icons, and it fits the menu bar.
    static let heightPoints = 18
    private static let offOpacity: CGFloat = 0.45
    /// Where the state badge goes, in the art's pixels: the empty corner right of the cursor's tip.
    /// A 5 pt badge here clears the cursor by more than 1 pt.
    private static let badgeCentre = CGPoint(x: 670, y: 825)

    /// The art's alpha scaled to one pixel density, trimmed to its ink.
    private struct Coverage {
        let width: Int
        let height: Int
        let scale: Int
        let alpha: [UInt8]
        /// Art pixels per output pixel, and the art's ink origin, to place badges in art coordinates.
        let artPerPixel: CGFloat
        let inkOrigin: CGPoint
    }

    private static let coverages: [Coverage]? = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let art = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let alpha = alphaChannel(of: art) else { return nil }
        guard let ink = inkBounds(alpha, width: art.width, height: art.height) else { return nil }
        return [1, 2].map { coverage(alpha, width: art.width, ink: ink, scale: $0) }
    }()

    static var hasArt: Bool { coverages != nil }

    /// The art when the resource is there, else the old SF Symbol; nil only if both are missing.
    static func image(_ glyph: Glyph, description: String) -> NSImage? {
        guard let coverages else {
            let symbol = glyph.fallbackSymbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: description) }.first
            symbol?.isTemplate = true
            return symbol
        }
        let image = NSImage(size: NSSize(width: CGFloat(coverages[0].width), height: CGFloat(coverages[0].height)))
        for c in coverages {
            if let rep = representation(of: glyph, from: c) { image.addRepresentation(rep) }
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func alphaChannel(of art: CGImage) -> [UInt8]? {
        var alpha = [UInt8](repeating: 0, count: art.width * art.height)
        let drawn: Bool = alpha.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: art.width, height: art.height, bitsPerComponent: 8,
                                      bytesPerRow: art.width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(art, in: CGRect(x: 0, y: 0, width: art.width, height: art.height))
            return true
        }
        return drawn ? alpha : nil
    }

    private static func inkBounds(_ alpha: [UInt8], width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 0 {
                box = (min(box?.minX ?? x, x), min(box?.minY ?? y, y), max(box?.maxX ?? x, x), max(box?.maxY ?? y, y))
            }
        }
        return box
    }

    /// Area-averages the ink so its height becomes exactly `heightPoints` at this density.
    private static func coverage(_ alpha: [UInt8], width: Int, ink: (minX: Int, minY: Int, maxX: Int, maxY: Int), scale: Int) -> Coverage {
        let inkW = ink.maxX - ink.minX + 1, inkH = ink.maxY - ink.minY + 1
        let outH = heightPoints * scale
        let pixelsPerArt = Double(outH) / Double(inkH)
        // A whole number of points wide, so the 1x and 2x bitmaps describe the same image size.
        let widthPoints = Int((Double(inkW) * pixelsPerArt / Double(scale)).rounded(.up))
        let outW = widthPoints * scale
        let xOffset = (Double(outW) - Double(inkW) * pixelsPerArt) / 2
        var sum = [Double](repeating: 0, count: outW * outH)
        for sy in 0..<inkH {
            let y0 = Double(sy) * pixelsPerArt, y1 = y0 + pixelsPerArt
            let rowStart = (sy + ink.minY) * width + ink.minX
            for sx in 0..<inkW {
                let value = Double(alpha[rowStart + sx])
                guard value > 0 else { continue }
                let x0 = Double(sx) * pixelsPerArt + xOffset, x1 = x0 + pixelsPerArt
                // Share this art pixel between the output pixels it overlaps.
                var oy = Int(y0)
                while oy < outH, Double(oy) < y1 {
                    let dy = min(y1, Double(oy + 1)) - max(y0, Double(oy))
                    var ox = Int(x0)
                    while ox < outW, Double(ox) < x1 {
                        sum[oy * outW + ox] += value * dy * (min(x1, Double(ox + 1)) - max(x0, Double(ox)))
                        ox += 1
                    }
                    oy += 1
                }
            }
        }
        return Coverage(width: widthPoints, height: heightPoints, scale: scale,
                        alpha: sum.map { UInt8(min(255, $0.rounded())) },
                        artPerPixel: 1 / pixelsPerArt,
                        inkOrigin: CGPoint(x: Double(ink.minX) - xOffset / pixelsPerArt, y: Double(ink.minY)))
    }

    private static func representation(of glyph: Glyph, from c: Coverage) -> NSBitmapImageRep? {
        let w = c.width * c.scale, h = c.height * c.scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        // Black, premultiplied: only the alpha byte is ever non-zero.
        let pixels = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w { pixels[y * ctx.bytesPerRow + x * 4 + 3] = c.alpha[y * w + x] }
        }
        applyVariant(glyph, to: ctx, coverage: c, height: h)
        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: c.width, height: c.height)
        return rep
    }

    private static func applyVariant(_ glyph: Glyph, to ctx: CGContext, coverage c: Coverage, height: Int) {
        if glyph == .off {
            ctx.setBlendMode(.destinationIn)
            ctx.setFillColor(CGColor(gray: 0, alpha: offOpacity))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            return
        }
        // The badge's centre on the pixel grid, then everything in points from there, y up.
        let px = CGFloat(c.scale)
        let cx = ((badgeCentre.x - c.inkOrigin.x) / c.artPerPixel).rounded()
        let cy = (CGFloat(height) - (badgeCentre.y - c.inkOrigin.y) / c.artPerPixel).rounded()
        ctx.translateBy(x: cx, y: cy)
        ctx.scaleBy(x: px, y: px)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        switch glyph {
        case .paused:
            // Two bars, the pause sign.
            ctx.fill(CGRect(x: -2, y: -2, width: 1.5, height: 4))
            ctx.fill(CGRect(x: 0.5, y: -2, width: 1.5, height: 4))
        case .calibrating:
            // A ring with a solid middle: a target to aim at.
            ctx.addEllipse(in: CGRect(x: -2.5, y: -2.5, width: 5, height: 5))
            ctx.addEllipse(in: CGRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2))
            ctx.fillPath(using: .evenOdd)
            ctx.fillEllipse(in: CGRect(x: -0.75, y: -0.75, width: 1.5, height: 1.5))
        case .away:
            // A crescent, the screen asleep: one circle with another bitten out of it.
            ctx.addRect(CGRect(x: -9, y: -9, width: 18, height: 18))
            ctx.addEllipse(in: CGRect(x: -1.1, y: -1.5, width: 4.4, height: 4.4))
            ctx.clip(using: .evenOdd)
            ctx.fillEllipse(in: CGRect(x: -2.5, y: -2.5, width: 5, height: 5))
        case .off, .tracking:
            break
        }
    }
}
