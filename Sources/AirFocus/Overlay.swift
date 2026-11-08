import AppKit
import QuartzCore
import AirFocusCore

/// Click-through, non-activating overlay panel, one per screen (R§5; Apple DTS, forum 826308):
/// accessory app + .nonactivatingPanel + .screenSaver level + these collection behaviours keep it
/// above full-screen Spaces without ever activating us.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true                 // click-through
        level = .screenSaver                      // .floating/.statusBar sit below full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false                 // we are never the active app
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Visual constants (spec §2.2). The user-chosen ones live in OverlayAppearance.
enum OverlayStyle {
    /// Calibration's small dots; the runtime dots use OverlayAppearance.dotSize.
    static let dotDiameter = CGFloat(SettingsDefault.dotSize)
    static let activeDotDiameter: CGFloat = 28
    static let cornerRadius: CGFloat = 12
    static let fadeDelay: TimeInterval = 1.0
    static let fadedOpacity: Float = 0.3

    static var accent: CGColor { NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? NSColor.systemBlue.cgColor }
    static func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
    static func black(_ a: CGFloat) -> CGColor { CGColor(gray: 0, alpha: a) }

    /// The rim that keeps a dot of this fill visible on both light and dark windows: the original
    /// dark rim at `alpha`, or a light one for a fill too dark for that to show.
    static func rim(for fill: CGColor, alpha: CGFloat) -> CGColor {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let c = fill.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components, c.count >= 3
        else { return black(alpha) }
        let light = StyleColor.needsLightRim(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
        return light ? white(0.85) : black(alpha)
    }
}

extension StyleColor {
    var cgColor: CGColor {
        followsAccent ? OverlayStyle.accent : CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum CalibrationDotState { case pending, active, done, skipped }

/// Draws everything for one screen, with CAShapeLayers in panel-local coordinates.
final class OverlayCanvas: NSView {
    var panelOrigin: CGPoint = .zero
    var primaryHeight: CGFloat = 0
    private var style = OverlayAppearance()

    private var dotLayers: [CGWindowID: CAShapeLayer] = [:]
    private let currentLayer = CAShapeLayer()
    private let pendingLayer = CAShapeLayer()
    private let ringTrack = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()
    private var calLayers: [CAShapeLayer] = []
    private let calRingTrack = CAShapeLayer()
    private let calRing = CAShapeLayer()
    private let cueDot = OverlayCanvas.dot(diameter: CGFloat(SettingsDefault.dotSize))
    private let cueRingTrack = CAShapeLayer()
    private let cueRing = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        currentLayer.fillColor = nil
        pendingLayer.fillColor = nil
        pendingLayer.lineDashPattern = [10, 6]
        ringTrack.strokeColor = OverlayStyle.white(0.35)
        for ring in [calRingTrack, calRing] { configureRing(ring, radius: 25, width: 4) }
        calRingTrack.strokeColor = OverlayStyle.white(0.3)
        shapePointer()
        pointerLayer.shadowColor = OverlayStyle.black(1)
        pointerLayer.shadowOpacity = 0.35
        pointerLayer.shadowRadius = 1.5
        pointerLayer.shadowOffset = .zero
        cueRingTrack.strokeColor = OverlayStyle.white(0.35)
        for l in [currentLayer, pendingLayer, ringTrack, ringLayer, calRingTrack, calRing, pointerLayer, cueDot, cueRingTrack, cueRing] {
            l.isHidden = true
            root.addSublayer(l)
        }
        pointerLayer.zPosition = 10
        for l in [cueDot, cueRingTrack, cueRing] { l.zPosition = 8 }
        apply(style)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureRing(_ ring: CAShapeLayer, radius: CGFloat, width: CGFloat) {
        ring.bounds = CGRect(x: 0, y: 0, width: radius * 2 + width, height: radius * 2 + width)
        let c = CGPoint(x: ring.bounds.midX, y: ring.bounds.midY)
        let p = CGMutablePath()
        p.addArc(center: c, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.path = p
        ring.fillColor = nil
        ring.lineWidth = width
        ring.lineCap = .round
    }

    /// Takes effect at once, on the layers already on screen. Paths that depend on the border width
    /// are rebuilt by the controller's next render.
    func apply(_ a: OverlayAppearance) {
        style = a
        withoutAnimation {
            currentLayer.lineWidth = a.borderWidth
            pendingLayer.lineWidth = a.pendingBorderWidth
            for ring in [ringTrack, ringLayer, cueRingTrack, cueRing] { configureRing(ring, radius: a.ringRadius, width: 3) }
            shapePointer()
            for l in dotLayers.values { styleDot(l) }
            styleDot(cueDot)
            refreshColors()
        }
    }

    /// Accent colour can change while running.
    func refreshColors() {
        let border = style.borderColor.cgColor
        let pointer = style.pointerColor.cgColor
        currentLayer.strokeColor = border
        pendingLayer.strokeColor = border.copy(alpha: 0.85 * border.alpha)
        ringLayer.strokeColor = border
        cueRing.strokeColor = border
        calRing.strokeColor = OverlayStyle.accent     // calibration's ring is not user-styled
        switch style.pointerShape {
        case .circle:
            pointerLayer.strokeColor = pointer.copy(alpha: 0.85 * pointer.alpha)
            pointerLayer.fillColor = pointer.copy(alpha: 0.15 * pointer.alpha)
        case .ring:
            pointerLayer.strokeColor = pointer.copy(alpha: 0.85 * pointer.alpha)
            pointerLayer.fillColor = nil
        case .dot:
            pointerLayer.strokeColor = nil
            pointerLayer.fillColor = pointer
        case .crosshair:
            pointerLayer.strokeColor = pointer
            pointerLayer.fillColor = nil
        }
    }

    private func shapePointer() {
        let d = CGFloat(style.pointerSize), line = CGFloat(style.pointerLineWidth)
        let box = CGRect(x: 0, y: 0, width: d, height: d)
        pointerLayer.bounds = box
        pointerLayer.lineWidth = line
        switch style.pointerShape {
        case .circle, .ring:
            pointerLayer.path = CGPath(ellipseIn: box.insetBy(dx: line * 0.6, dy: line * 0.6), transform: nil)
        case .dot:
            pointerLayer.path = CGPath(ellipseIn: box, transform: nil)
        case .crosshair:
            // Four arms around an open centre, so it never covers what's under it.
            let c = d / 2, gap = max(2, d * 0.18)
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: 0, y: c), CGPoint(x: c - gap, y: c)])
            path.addLines(between: [CGPoint(x: c + gap, y: c), CGPoint(x: d, y: c)])
            path.addLines(between: [CGPoint(x: c, y: 0), CGPoint(x: c, y: c - gap)])
            path.addLines(between: [CGPoint(x: c, y: c + gap), CGPoint(x: c, y: d)])
            pointerLayer.path = path
        }
    }

    private func local(_ p: CGPoint) -> CGPoint {
        Geometry.localPoint(fromCG: p, panelOrigin: panelOrigin, primaryHeight: primaryHeight)
    }

    private func local(_ r: CGRect) -> CGRect {
        Geometry.localRect(fromCG: r, panelOrigin: panelOrigin, primaryHeight: primaryHeight)
    }

    private func borderPath(_ frameCG: CGRect) -> CGPath {
        let inset = style.borderWidth / 2     // the stroke stays inside the window's frame
        return CGPath(roundedRect: local(frameCG).insetBy(dx: inset, dy: inset), cornerWidth: OverlayStyle.cornerRadius,
                      cornerHeight: OverlayStyle.cornerRadius, transform: nil)
    }

    private func styleDot(_ l: CAShapeLayer) {
        Self.setDotShape(l, diameter: style.dotSize)
        let fill = style.dotColor.cgColor
        l.fillColor = fill
        l.strokeColor = OverlayStyle.rim(for: fill, alpha: 0.55)
    }

    private static func setDotShape(_ l: CAShapeLayer, diameter: CGFloat) {
        l.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        l.path = CGPath(ellipseIn: l.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        l.shadowPath = l.path
    }

    fileprivate static func dot(diameter: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        setDotShape(l, diameter: diameter)
        l.fillColor = OverlayStyle.white(1)
        l.strokeColor = OverlayStyle.black(0.55)    // dark rim so it shows on white backgrounds
        l.lineWidth = 1.5
        l.shadowColor = OverlayStyle.black(1)
        l.shadowOpacity = 0.45
        l.shadowRadius = 2
        l.shadowOffset = CGSize(width: 0, height: -1)
        return l
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Tracking

    func setDots(_ windows: [TrackedWindow], visible: Bool) {
        guard let root = layer else { return }
        withoutAnimation {
            var seen = Set<CGWindowID>()
            if visible {
                for w in windows {
                    seen.insert(w.id)
                    let l = dotLayers[w.id] ?? {
                        let n = Self.dot(diameter: style.dotSize)
                        styleDot(n)
                        n.zPosition = 5
                        root.addSublayer(n)
                        dotLayers[w.id] = n
                        return n
                    }()
                    l.position = local(w.targetPointCG)
                }
            }
            for (id, l) in dotLayers where !seen.contains(id) {
                l.removeFromSuperlayer()
                dotLayers.removeValue(forKey: id)
            }
        }
    }

    /// `faded` = the persistent faint outline; animate the transition from solid to faded.
    func setCurrent(frameCG: CGRect?, faded: Bool, animateFade: Bool) {
        guard let f = frameCG else {
            withoutAnimation { currentLayer.isHidden = true }
            return
        }
        withoutAnimation {
            currentLayer.path = borderPath(f)
            currentLayer.isHidden = false
            if !animateFade { currentLayer.opacity = faded ? OverlayStyle.fadedOpacity : 1 }
        }
        if animateFade {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            currentLayer.opacity = faded ? OverlayStyle.fadedOpacity : 1
            CATransaction.commit()
        }
    }

    func setPending(frameCG: CGRect?, dotCG: CGPoint?, progress: Double?) {
        withoutAnimation {
            if let f = frameCG {
                pendingLayer.path = borderPath(f)
                pendingLayer.isHidden = false
            } else {
                pendingLayer.isHidden = true
            }
            if let d = dotCG, let progress {
                let p = local(d)
                ringTrack.position = p
                ringLayer.position = p
                ringLayer.strokeEnd = CGFloat(max(0.02, min(1, progress)))
                ringTrack.isHidden = false
                ringLayer.isHidden = false
            } else {
                ringTrack.isHidden = true
                ringLayer.isHidden = true
            }
        }
    }

    func setPointer(_ p: CGPoint?) {
        withoutAnimation {
            if let p {
                pointerLayer.position = local(p)
                pointerLayer.isHidden = false
            } else {
                pointerLayer.isHidden = true
            }
        }
    }

    /// For the offscreen layout check: where things actually are, in panel-local points.
    var layout: (dots: [CGWindowID: CGPoint], current: CGRect?, pending: CGRect?, pointer: Bool) {
        (dotLayers.mapValues(\.position),
         currentLayer.isHidden ? nil : currentLayer.path?.boundingBox,
         pendingLayer.isHidden ? nil : pendingLayer.path?.boundingBox,
         !pointerLayer.isHidden)
    }

    func clearTracking() {
        setDots([], visible: false)
        setCurrent(frameCG: nil, faded: false, animateFade: false)
        setPending(frameCG: nil, dotCG: nil, progress: nil)
        setPointer(nil)
    }

    // MARK: Recenter cue

    /// Hidden mode's ⌃⌥⌘R cue: the focused window's dot, in the user's dot style, with a ring that
    /// fills over `duration` (Core Animation runs it; nothing ticks). With no duration the ring
    /// stays at `progress`, for the offscreen render.
    func showRecenterCue(at p: CGPoint, progress: Double, duration: TimeInterval?) {
        withoutAnimation {
            let lp = local(p)
            for l in [cueDot, cueRingTrack, cueRing] {
                l.removeAllAnimations()
                l.position = lp
                l.opacity = 1
                l.isHidden = false
            }
            cueRing.strokeEnd = duration == nil ? CGFloat(max(0.02, min(1, progress))) : 1
        }
        guard let duration else { return }
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0.02
        fill.toValue = 1
        fill.duration = duration
        cueRing.add(fill, forKey: "fill")
    }

    /// The recenter happened: fade the cue out.
    func fadeRecenterCue(over seconds: TimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(seconds)
        for l in [cueDot, cueRingTrack, cueRing] { l.opacity = 0 }
        CATransaction.commit()
    }

    func hideRecenterCue() {
        withoutAnimation {
            for l in [cueDot, cueRingTrack, cueRing] {
                l.removeAllAnimations()
                l.isHidden = true
            }
        }
    }

    var recenterCueShown: Bool { !cueDot.isHidden }

    // MARK: Calibration

    func setCalibration(_ dots: [(CGPoint, CalibrationDotState)], progress: Double) {
        guard let root = layer else { return }
        withoutAnimation {
            while calLayers.count > dots.count { calLayers.removeLast().removeFromSuperlayer() }
            while calLayers.count < dots.count {
                let l = Self.dot(diameter: OverlayStyle.activeDotDiameter)
                l.zPosition = 6
                root.addSublayer(l)
                calLayers.append(l)
            }
            var activePoint: CGPoint?
            for (i, (p, state)) in dots.enumerated() {
                let l = calLayers[i]
                l.position = local(p)
                let small = OverlayStyle.dotDiameter / OverlayStyle.activeDotDiameter
                switch state {
                case .pending:
                    l.fillColor = OverlayStyle.white(0.35)
                    l.strokeColor = OverlayStyle.black(0.3)
                    l.shadowOpacity = 0
                    setScale(l, small, pulsing: false)
                case .done:
                    l.fillColor = NSColor.systemGreen.cgColor
                    l.strokeColor = OverlayStyle.black(0.5)
                    l.shadowOpacity = 0.4
                    setScale(l, small * 1.15, pulsing: false)
                case .skipped:
                    l.fillColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
                    l.strokeColor = OverlayStyle.black(0.5)
                    l.shadowOpacity = 0.4
                    setScale(l, small, pulsing: false)
                case .active:
                    let fill = style.dotColor.cgColor
                    l.fillColor = fill
                    l.strokeColor = OverlayStyle.rim(for: fill, alpha: 0.6)
                    l.shadowOpacity = 0.6
                    setScale(l, 1, pulsing: true)
                    activePoint = p
                }
            }
            if let a = activePoint {
                let lp = local(a)
                calRingTrack.position = lp
                calRing.position = lp
                calRing.strokeEnd = CGFloat(max(0.0, min(1, progress)))
                calRingTrack.isHidden = false
                calRing.isHidden = progress <= 0
            } else {
                calRingTrack.isHidden = true
                calRing.isHidden = true
            }
        }
    }

    private func setScale(_ l: CAShapeLayer, _ s: CGFloat, pulsing: Bool) {
        l.transform = CATransform3DMakeScale(s, s, 1)
        let hasPulse = l.animation(forKey: "pulse") != nil
        if pulsing && !hasPulse {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1.0
            a.toValue = 1.22
            a.duration = 0.55
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(a, forKey: "pulse")
        } else if !pulsing && hasPulse {
            l.removeAnimation(forKey: "pulse")
        }
    }

    func clearCalibration() { setCalibration([], progress: 0) }
}

/// The instruction / result banner.
final class BannerView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = OverlayStyle.black(0.78)
        layer?.borderColor = OverlayStyle.white(0.15)
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(text: String, style: OverlayController.BannerStyle) {
        label.stringValue = text
        switch style {
        case .info: layer?.borderColor = OverlayStyle.white(0.15)
        case .success: layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
        case .warning: layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        }
    }

    /// Sizes itself to the text, at most `maxWidth` wide.
    func fit(maxWidth: CGFloat) -> NSSize {
        let pad = NSSize(width: 22, height: 12)
        label.preferredMaxLayoutWidth = maxWidth - pad.width * 2
        let s = label.sizeThatFits(NSSize(width: maxWidth - pad.width * 2, height: 200))
        let size = NSSize(width: ceil(min(maxWidth, s.width + pad.width * 2)), height: ceil(s.height + pad.height * 2))
        label.frame = NSRect(x: pad.width, y: pad.height, width: size.width - pad.width * 2, height: ceil(s.height))
        return size
    }
}

/// Owns the panels and the overlay state; everything is in CG global coordinates.
@MainActor
final class OverlayController {
    enum Mode { case hidden, tracking, calibrating }
    enum BannerStyle { case info, success, warning }

    private struct PanelSet {
        let screenFrameCG: CGRect
        let panel: OverlayPanel
        let canvas: OverlayCanvas
        let banner: BannerView
    }

    private var panels: [PanelSet] = []
    private(set) var mode: Mode = .hidden
    private(set) var appearance = OverlayAppearance()
    /// The user's Overlay setting. Hidden: tracking draws nothing; calibration, essential banners,
    /// Mission Control's pointer and pick, and the recenter cue still do. The app sets the stored
    /// mode at launch; Visible here keeps the CLI previews as they were.
    private(set) var overlayMode: OverlayMode = .visible
    /// The CLI's render flags: draw into the panels but never order them onto the real screen.
    private let offscreen: Bool
    private var suspended = false
    private var pointerOnly = false
    private var pickFrame: CGRect?
    private var pickProgress: Double?
    private var screenObserver: NSObjectProtocol?

    // Tracking state
    private var windows: [TrackedWindow] = []
    private var currentID: CGWindowID?
    private var currentFaded = false
    private var currentGeneration = 0
    private var fadeEnabled = true
    private var pendingID: CGWindowID?
    private var pendingProgress: Double?
    private var pointer: CGPoint?
    private var pointerShown = false

    // Recenter cue
    private var cuePoint: CGPoint?
    private var cueGeneration = 0

    // Calibration state
    private var calDots: [(CGPoint, CalibrationDotState)] = []
    private var calProgress = 0.0

    // Banner
    private var bannerText: String?
    private var bannerIsStatus = false
    private var bannerStyle: BannerStyle = .info
    private var bannerAnchorCG: CGPoint?
    private var bannerGeneration = 0

    init(offscreen: Bool = false) {
        self.offscreen = offscreen
        rebuildPanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info(.app, "screen configuration changed: rebuilding overlay panels")
                self?.rebuildPanels()
            }
        }
    }

    /// One panel per screen; rebuilt whenever the screen configuration changes.
    func rebuildPanels() {
        panels.forEach { $0.panel.orderOut(nil) }
        let h = Screens.primaryHeight
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen)
            let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let canvas = OverlayCanvas(frame: root.bounds)
            canvas.autoresizingMask = [.width, .height]
            canvas.panelOrigin = screen.frame.origin
            canvas.primaryHeight = h
            canvas.apply(appearance)
            let banner = BannerView(frame: .zero)
            banner.isHidden = true
            root.addSubview(canvas)
            root.addSubview(banner)
            panel.contentView = root
            return PanelSet(screenFrameCG: Geometry.cgRect(fromAppKit: screen.frame, primaryHeight: h),
                            panel: panel, canvas: canvas, banner: banner)
        }
        renderAll()
        updateVisibility()
    }

    private var shouldShow: Bool { !suspended && (mode != .hidden || bannerText != nil || cuePoint != nil) }

    /// Dots, borders, the ring and the pointer draw while tracking only in Visible mode.
    private var drawsTracking: Bool { mode == .tracking && overlayMode == .visible }

    private func updateVisibility() {
        guard !offscreen else { return }
        for p in panels {
            if shouldShow { p.panel.orderFrontRegardless() } else { p.panel.orderOut(nil) }
        }
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        if m != .tracking { panels.forEach { $0.canvas.clearTracking() } }
        if m != .calibrating { calDots = []; panels.forEach { $0.canvas.clearCalibration() } }
        if m == .tracking { panels.forEach { $0.canvas.refreshColors() } }
        renderAll()
        updateVisibility()
    }

    /// Hidden while the screen saver runs or the session is locked (R§9.2: a .screenSaver-level
    /// panel would otherwise draw over a running screen saver).
    func setSuspended(_ s: Bool) {
        guard s != suspended else { return }
        suspended = s
        updateVisibility()
    }

    /// Hidden or Visible. Switching to Hidden drops what tracking drew and any status banner.
    func setOverlayMode(_ m: OverlayMode) {
        guard m != overlayMode else { return }
        overlayMode = m
        if m == .hidden && bannerIsStatus { hideBanner() }
        renderAll()
        if m == .visible { emphasizeCurrent() }    // arm the fade on a border that just appeared
    }

    /// Mission Control rearranges every window, so dots and borders would mark the wrong places.
    /// Only the pointer still means something there. The panel ignores clicks, so it can't get in the way.
    func setPointerOnly(_ on: Bool) {
        guard on != pointerOnly else { return }
        pointerOnly = on
        if on && bannerIsStatus { hideBanner() }
        renderAll()
    }

    /// The Mission Control thumbnail being held, drawn like a window about to be switched to.
    func update(pick frame: CGRect?, progress: Double?) {
        guard frame != pickFrame || progress != pickProgress else { return }
        pickFrame = frame
        pickProgress = progress
        renderPending()
    }

    /// Restyle everything now, including what is already on screen. Calibration is unaffected except
    /// for the active dot's colour: the toggles only govern the runtime overlay.
    func apply(_ a: OverlayAppearance) {
        guard a != appearance else { return }
        let borderChanged = a.showBorder != appearance.showBorder || a.borderColor != appearance.borderColor
            || a.borderWidth != appearance.borderWidth
        appearance = a
        panels.forEach { $0.canvas.apply(a) }
        renderAll()
        if !a.showBanners && bannerIsStatus { hideBanner() }
        // The border may have faded to a faint outline: make the change visible.
        if borderChanged { emphasizeCurrent() }
    }

    // MARK: Tracking updates

    func update(windows: [TrackedWindow]) {
        self.windows = windows
        guard drawsTracking else { return }     // nothing to move in Hidden mode
        renderDots()
        renderCurrent(animateFade: false)
        renderPending()
    }

    /// `current` = the focused target (solid, fading to a faint outline after ~1 s);
    /// `pending` = the candidate whose dwell is running (dashed border + progress ring around its dot,
    /// or no ring when `progress` is nil, as in hotkey-only mode).
    func update(current: CGWindowID?, pending: CGWindowID?, progress: Double?) {
        update(current: current)
        update(pending: pending, progress: progress)
    }

    func update(current: CGWindowID?) {
        if current != currentID {
            currentID = current
            currentFaded = false
            currentGeneration += 1
            let gen = currentGeneration
            if current != nil && fadeEnabled && overlayMode == .visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + OverlayStyle.fadeDelay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.currentGeneration == gen else { return }
                        self.currentFaded = true
                        self.renderCurrent(animateFade: true)
                    }
                }
            }
            renderCurrent(animateFade: false)
            if pendingID == current { pendingID = nil; renderPending() }
        }
    }

    func update(pending: CGWindowID?, progress: Double?) {
        let p = pending == currentID ? nil : pending
        guard p != pendingID || progress != pendingProgress else { return }
        pendingID = p
        pendingProgress = progress
        guard drawsTracking else { return }      // Hidden: the dwell runs, nothing draws it
        renderPending()
    }

    /// Make the current highlight solid again (e.g. while asking the user to look at it).
    func emphasizeCurrent() {
        let id = currentID
        currentID = nil
        update(current: id)
    }

    func update(pointer p: CGPoint?) {
        pointer = p
        guard mode == .tracking else { return }
        renderPointer()
    }

    // MARK: Recenter cue

    /// Hidden mode's ⌃⌥⌘R cue at the focused window's dot; a new one restarts the ring.
    func showRecenterCue(at p: CGPoint, duration: TimeInterval) {
        showRecenterCue(at: p, progress: 0, animated: duration)
    }

    /// For the offscreen render: the ring stopped at `progress`.
    func showRecenterCue(at p: CGPoint, progress: Double) {
        showRecenterCue(at: p, progress: progress, animated: nil)
    }

    private func showRecenterCue(at p: CGPoint, progress: Double, animated duration: TimeInterval?) {
        cueGeneration += 1
        cuePoint = p
        panels.forEach { $0.canvas.showRecenterCue(at: p, progress: progress, duration: duration) }
        updateVisibility()
    }

    /// Recentered: the dot fades out, then the cue is gone (one deferred step, no timer left running).
    func finishRecenterCue() {
        guard cuePoint != nil else { return }
        let fade = 0.35
        panels.forEach { $0.canvas.fadeRecenterCue(over: fade) }
        let gen = cueGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.cueGeneration == gen else { return }
                self.cancelRecenterCue()
            }
        }
    }

    func cancelRecenterCue() {
        guard cuePoint != nil else { return }
        cueGeneration += 1
        cuePoint = nil
        panels.forEach { $0.canvas.hideRecenterCue() }
        updateVisibility()
    }

    var recenterCueShowing: Bool { cuePoint != nil }

    /// For --overlay-preview: keep the current highlight solid so a screenshot shows it.
    func disableFade() { fadeEnabled = false }

    /// Mission Control keeps its pointer in both modes: it's a mode the user chose to enter.
    private func renderPointer() {
        let drawn = appearance.showPointer && (overlayMode == .visible || pointerOnly)
        let p = drawn ? pointer : nil
        guard p != nil || pointerShown else { return }     // already hidden: no work per sample
        pointerShown = p != nil
        panels.forEach { $0.canvas.setPointer(p) }
    }

    private func renderDots() {
        let visible = drawsTracking && appearance.showDots && !pointerOnly
        panels.forEach { $0.canvas.setDots(windows, visible: visible) }
    }

    private func renderCurrent(animateFade: Bool) {
        let frame = drawsTracking && appearance.showBorder && !pointerOnly
            ? currentID.flatMap { id in windows.first { $0.id == id }?.frameCG } : nil
        panels.forEach { $0.canvas.setCurrent(frameCG: frame, faded: currentFaded, animateFade: animateFade) }
    }

    private func renderPending() {
        if pointerOnly {
            let centre = pickFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            panels.forEach {
                $0.canvas.setPending(frameCG: appearance.showBorder ? pickFrame : nil, dotCG: centre,
                                     progress: appearance.showRing ? pickProgress : nil)
            }
            return
        }
        let w = drawsTracking && !pointerOnly ? pendingID.flatMap { id in windows.first { $0.id == id } } : nil
        // The ring is display only: turning it off leaves the dwell running exactly as before.
        let frame = appearance.showBorder ? w?.frameCG : nil
        let progress = appearance.showRing && w != nil ? pendingProgress : nil
        panels.forEach { $0.canvas.setPending(frameCG: frame, dotCG: w?.targetPointCG, progress: progress) }
    }

    // MARK: Calibration updates

    func update(calibration dots: [(CGPoint, CalibrationDotState)], progress: Double) {
        calDots = dots
        calProgress = progress
        guard mode == .calibrating else { return }
        panels.forEach { $0.canvas.setCalibration(dots, progress: progress) }
    }

    // MARK: Banner

    /// Shows a centred banner near the top of the screen containing `anchorCG` (default: the
    /// primary screen), moving to the bottom if `anchorCG` itself sits under the top band.
    /// `duration` nil = until replaced or hidden. `status` marks a non-essential banner, which the
    /// Status Banners setting and Hidden mode turn off; calibration, permission and error banners always show.
    func showBanner(_ text: String, style: BannerStyle = .info, duration: TimeInterval? = nil, near anchorCG: CGPoint? = nil,
                    status: Bool = false) {
        if status && (!appearance.showBanners || overlayMode == .hidden) { return }
        bannerText = text
        bannerIsStatus = status
        bannerStyle = style
        bannerAnchorCG = anchorCG
        bannerGeneration += 1
        let gen = bannerGeneration
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.bannerGeneration == gen else { return }
                    self.hideBanner()
                }
            }
        }
        renderBanner()
        updateVisibility()
    }

    func hideBanner() {
        bannerText = nil
        bannerIsStatus = false
        bannerGeneration += 1
        renderBanner()
        updateVisibility()
    }

    var bannerIsShowing: Bool { bannerText != nil }

    private func renderBanner() {
        let anchor = bannerAnchorCG
        let target = panels.firstIndex { p in anchor.map { p.screenFrameCG.contains($0) } ?? false } ?? 0
        for (i, p) in panels.enumerated() {
            guard i == target, let text = bannerText else { p.banner.isHidden = true; continue }
            p.banner.set(text: text, style: bannerStyle)
            let bounds = p.canvas.bounds
            let size = p.banner.fit(maxWidth: min(820, bounds.width - 80))
            let topY = bounds.height - bounds.height * 0.14 - size.height
            var y = topY
            if let a = anchor {
                let local = Geometry.localPoint(fromCG: a, panelOrigin: p.panel.frame.origin, primaryHeight: Screens.primaryHeight)
                if local.y > topY - 50 { y = bounds.height * 0.10 }      // anchor under the top band: go low
            }
            p.banner.frame = NSRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
            p.banner.isHidden = false
        }
    }

    /// Offscreen render of one screen's overlay (no Screen Recording needed), over a grey
    /// background with `referenceFrames` outlined so positions can be checked. Animations are
    /// not rendered (model values only).
    func snapshot(screen index: Int, referenceFrames: [CGRect]) -> NSBitmapImageRep? {
        guard panels.indices.contains(index) else { return nil }
        let p = panels[index]
        p.panel.contentView?.layoutSubtreeIfNeeded()
        p.panel.displayIfNeeded()
        let size = p.canvas.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        ctx.setFillColor(CGColor(gray: 0.22, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.setLineWidth(1)
        for f in referenceFrames {
            ctx.stroke(Geometry.localRect(fromCG: f, panelOrigin: p.panel.frame.origin, primaryHeight: Screens.primaryHeight))
        }
        p.canvas.layer?.render(in: ctx)
        if !p.banner.isHidden, let layer = p.banner.layer {
            ctx.saveGState()
            ctx.translateBy(x: p.banner.frame.minX, y: p.banner.frame.minY)
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        return rep
    }

    func layout(screen index: Int) -> (dots: [CGWindowID: CGPoint], current: CGRect?, pending: CGRect?, pointer: Bool,
                                       cue: Bool, panelOrigin: CGPoint)? {
        guard panels.indices.contains(index) else { return nil }
        let l = panels[index].canvas.layout
        return (l.dots, l.current, l.pending, l.pointer, panels[index].canvas.recenterCueShown, panels[index].panel.frame.origin)
    }

    private func renderAll() {
        renderDots()
        renderCurrent(animateFade: false)
        renderPending()
        if mode == .tracking { pointerShown = true; renderPointer() }
        if mode == .calibrating { panels.forEach { $0.canvas.setCalibration(calDots, progress: calProgress) } }
        renderBanner()
    }
}
