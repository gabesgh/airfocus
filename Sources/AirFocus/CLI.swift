import AppKit
import CoreMotion
import AirFocusCore

/// Headless diagnostics (spec §3.2). Each mode prints and exits without the menu bar UI.
/// Run from the bundled binary: build/AirFocus.app/Contents/MacOS/AirFocus --diagnose
@MainActor
enum CLI {
    enum Mode {
        case diagnose
        case listWindows
        case overlayPreview(seconds: Double)
        case renderOverlay(path: String, calibration: Bool, demoWindows: Bool, pointerOnly: Bool, recenterCue: Bool, style: String?)
        case renderSettings(path: String, section: SettingsSection, dark: Bool, visual: SettingsVisual, style: String?)
        case renderMenuBarIcons(directory: String)
        case replayTrace(path: String, engines: TraceReplay.Engines, set: String?)
        case synthesizeTrace(path: String, seed: UInt64, scenarios: String?)
        case help
    }

    static func mode(from args: [String]) -> Mode? {
        let a = Array(args.dropFirst())
        if a.contains("--help") || a.contains("-h") { return .help }
        if a.contains("--diagnose") { return .diagnose }
        if a.contains("--list-windows") { return .listWindows }
        if let i = a.firstIndex(of: "--overlay-preview") {
            let secs = a.indices.contains(i + 1) ? Double(a[i + 1]) : nil
            return .overlayPreview(seconds: max(0.5, secs ?? 5))
        }
        func option(_ name: String) -> String? {
            a.firstIndex(of: name).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
        }
        if let i = a.firstIndex(of: "--render-overlay"), a.indices.contains(i + 1) {
            return .renderOverlay(path: a[i + 1], calibration: a.dropFirst(i + 2).first == "calibration",
                                  demoWindows: a.contains("--demo-windows"), pointerOnly: a.contains("--pointer-only"),
                                  recenterCue: a.contains("--recenter-cue"), style: option("--style"))
        }
        if let path = option("--replay-trace") {
            guard let engines = TraceReplay.Engines(rawValue: option("--engine") ?? "both") else { return .help }
            return .replayTrace(path: path, engines: engines, set: option("--set"))
        }
        if let path = option("--synthesize-trace") {
            return .synthesizeTrace(path: path, seed: option("--seed").flatMap { UInt64($0) } ?? 7, scenarios: option("--scenarios"))
        }
        if let path = option("--render-settings") {
            let section = SettingsSection.allCases.first { $0.rawValue.lowercased() == option("--section")?.lowercased() } ?? .tracking
            return .renderSettings(path: path, section: section, dark: option("--appearance") == "dark",
                                   visual: SettingsVisual(reduceTransparency: a.contains("--reduce-transparency"),
                                                          increaseContrast: a.contains("--increase-contrast")),
                                   style: option("--style"))
        }
        if let directory = option("--render-menubar-icons") { return .renderMenuBarIcons(directory: directory) }
        // A mistyped or unknown flag must not fall through to launching the menu bar app.
        if a.contains(where: { $0.hasPrefix("--") }) { return .help }
        return nil
    }

    static func run(_ mode: Mode) -> Int32 {
        Log.fileLoggingEnabled = false
        switch mode {
        case .help:
            print("""
            AirFocus \(Diagnostics.version)
              (no flags)                 run the menu bar app (launch it with `open`, not from a terminal)
              --diagnose                 print environment, permissions, private symbols, screens, calibration
              --list-windows             print the tracked windows after filtering
              --overlay-preview [secs]   show the runtime overlay on the current windows for N seconds (default 5)
              --render-overlay FILE.png [tracking|calibration] [--demo-windows] [--pointer-only] [--recenter-cue]
                               [--style K=V,...]
                                         render the primary screen's overlay offscreen to a PNG (no Screen
                                         Recording needed); window frames are outlined in grey. Uses the
                                         stored settings, overridden by --style. --demo-windows draws fixed
                                         windows instead of the real ones. --pointer-only draws what stays
                                         while Mission Control is open. --recenter-cue adds Hidden mode's
                                         ⌃⌥⌘R dot, its ring 60% full
              --render-settings FILE.png [--section tracking|appearance|lookAway|general]
                                         [--appearance light|dark] [--reduce-transparency]
                                         [--increase-contrast] [--style K=V,...]
                                         render the Settings window offscreen with default settings. Layout
                                         and text only: Liquid Glass does not render offscreen
              --render-menubar-icons DIR render every menu bar icon state at actual size and 8×, light and dark
              --replay-trace FILE|DIR [--engine live|intent|both] [--set NAME=VALUE,...]
                                         replay session traces (.aftrace or .aftrace.gz; a directory replays every
                                         trace in it, in name order) through the live path and the intent
                                         engine, and compare them. --set overrides intent engine parameters
              --synthesize-trace FILE [--seed N] [--scenarios NAME,...]
                                         write a synthetic trace (a simulated head and user, the live path
                                         running on them) for trying --replay-trace. Scenarios: \(TraceSynthesizer.Scenario.allCases.map(\.rawValue).joined(separator: " "))
            --style keys: overlay(hidden|visible) showDots dotColor dotSize showBorder borderColor borderWidth showPointer
            pointerColor pointerShape pointerSize showRing showBanners sensitivity; colours are #RRGGBB or accent, for example
            overlay=visible,dotColor=#FF3B30,showRing=false
            intent engine parameters for --set: \(IntentEngine.Parameters.names.map(\.0).joined(separator: " "))
            """)
            return 0
        case .diagnose:
            _ = NSApplication.shared
            print(Diagnostics.report(includeHotkeyProbe: true))
            return 0
        case .listWindows:
            _ = NSApplication.shared
            listWindows()
            return 0
        case .overlayPreview(let secs):
            return overlayPreview(seconds: secs)
        case .renderOverlay(let path, let calibration, let demoWindows, let pointerOnly, let recenterCue, let style):
            return renderOverlay(to: path, calibration: calibration, demoWindows: demoWindows, pointerOnly: pointerOnly,
                                 recenterCue: recenterCue, style: style)
        case .renderSettings(let path, let section, let dark, let visual, let style):
            return renderSettings(to: path, section: section, dark: dark, visual: visual, style: style)
        case .renderMenuBarIcons(let directory):
            return renderMenuBarIcons(to: directory)
        case .replayTrace(let path, let engines, let set):
            return replayTrace(path, engines: engines, set: set)
        case .synthesizeTrace(let path, let seed, let scenarios):
            return synthesizeTrace(to: path, seed: seed, scenarios: scenarios)
        }
    }

    /// Every trace at `path` through both engines, in order; prints the comparison. Deterministic.
    private static func replayTrace(_ path: String, engines: TraceReplay.Engines, set: String?) -> Int32 {
        var parameters = IntentEngine.Parameters()
        if let set, let bad = parameters.apply(overrides: set) {
            print("unknown or unreadable --set \(bad); names: \(IntentEngine.Parameters.names.map(\.0).joined(separator: " "))")
            return 1
        }
        let files = TraceFile.list(path)
        guard !files.isEmpty else { print("no traces at \(path)"); return 1 }
        var replay = TraceReplay(engines: engines, parameters: parameters)
        for url in files {
            guard let (events, skipped) = TraceFile.read(url) else { print("cannot read \(url.lastPathComponent)"); return 1 }
            replay.feed(events, skipped: skipped)
        }
        replay.finish()
        print(replay.table())
        return 0
    }

    private static func synthesizeTrace(to path: String, seed: UInt64, scenarios: String?) -> Int32 {
        var chosen = TraceSynthesizer.Scenario.allCases
        if let scenarios {
            let names = scenarios.split(separator: ",").map(String.init)
            let picked = names.compactMap(TraceSynthesizer.Scenario.init(rawValue:))
            guard picked.count == names.count else {
                print("scenarios: \(TraceSynthesizer.Scenario.allCases.map(\.rawValue).joined(separator: " "))")
                return 1
            }
            chosen = picked
        }
        let events = TraceSynthesizer.events(chosen, seed: seed)
        let text = TraceSynthesizer.text(events)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { print("write failed: \(error)"); return 1 }
        print("wrote \(path): \(chosen.count) scenario(s), \(events.count) events, \(text.utf8.count / 1024) KB")
        return 0
    }

    private static func listWindows() {
        let r = WindowEnumerator().snapshot()
        print("\(r.windows.count) tracked window(s) of \(r.rawCount) on-screen entries (front to back)\n")
        let header = ["#", "wid", "pid", "app", "frame (CG x,y w×h)", "visible", "dot (CG)"]
        var rows: [[String]] = [header]
        for (i, w) in r.windows.enumerated() {
            let f = w.frameCG
            rows.append([
                "\(i + 1)", "\(w.id)", "\(w.pid)", w.appName,
                "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))",
                String(format: "%.0f%%", w.visibleFraction * 100),
                "\(Int(w.targetPointCG.x)),\(Int(w.targetPointCG.y))",
            ])
        }
        let widths = header.indices.map { c in rows.map { $0[c].count }.max() ?? 0 }
        for row in rows {
            print(row.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  "))
        }
        let rejected = WindowRejection.allCases.compactMap { reason in r.rejections[reason].map { "\($0) \(reason.rawValue)" } }
        if !rejected.isEmpty { print("\nrejected: " + rejected.joined(separator: "; ")) }
        if Screens.stageManagerEnabled { print("Stage Manager is on: strip thumbnails are filtered out.") }
    }

    /// Settings for a render: the defaults plus "--style key=value,...", or nil for anything it can't
    /// read. Everything sits in the volatile registration domain of a suite nothing ever writes to,
    /// so a render leaves no trace in the app's preferences or on disk.
    private static func scratchSettings(style: String?) -> AppSettings? {
        let suite = "com.gshimoon.airfocus.render-scratch.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        let settings = AppSettings(defaults: defaults)
        let toggles = ["showDots": SettingsKey.showWindowDots, "showBorder": SettingsKey.showFocusBorder,
                       "showPointer": SettingsKey.showHeadPointer, "showRing": SettingsKey.showProgressRing,
                       "showBanners": SettingsKey.showStatusBanners]
        let colours = ["dotColor": SettingsKey.dotColor, "borderColor": SettingsKey.borderColor, "pointerColor": SettingsKey.pointerColor]
        let numbers = ["dotSize": SettingsKey.dotSize, "borderWidth": SettingsKey.borderWidth, "pointerSize": SettingsKey.pointerSize,
                       "sensitivity": SettingsKey.sensitivity]
        var values: [String: Any] = [:]
        for pair in (style ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            if let key = toggles[kv[0]], kv[1] == "true" || kv[1] == "false" {
                values[key] = kv[1] == "true"
            } else if let key = colours[kv[0]], let color = StyleColor(hexOrAccent: kv[1]) {
                values[key] = color.storageString
            } else if let key = numbers[kv[0]], let number = Double(kv[1]) {
                values[key] = number
            } else if kv[0] == "pointerShape", PointerShape(rawValue: kv[1]) != nil {
                values[SettingsKey.pointerShape] = kv[1]
            } else if kv[0] == "overlay", OverlayMode(rawValue: kv[1]) != nil {
                values[SettingsKey.overlayMode] = kv[1]
            } else {
                return nil
            }
        }
        defaults.register(defaults: values)
        return settings
    }

    /// Fixed windows for --demo-windows, so two renders can be compared pixel for pixel.
    private static let demoWindows = [
        TrackedWindow(id: 101, pid: 1, appName: "Demo A", frameCG: CGRect(x: 120, y: 140, width: 620, height: 420)),
        TrackedWindow(id: 102, pid: 1, appName: "Demo B", frameCG: CGRect(x: 780, y: 140, width: 560, height: 420)),
        TrackedWindow(id: 103, pid: 1, appName: "Demo C", frameCG: CGRect(x: 120, y: 600, width: 620, height: 260)),
    ]

    /// Same scene as --overlay-preview (or a mid-calibration scene), rendered offscreen. The panels
    /// are never ordered onto the screen. Stored settings are only read; --style replaces them.
    private static func renderOverlay(to path: String, calibration: Bool, demoWindows useDemo: Bool, pointerOnly: Bool,
                                      recenterCue: Bool, style: String?) -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)
        let windows = useDemo ? demoWindows : WindowEnumerator().snapshot().windows
        var source = AppSettings()
        if let style {
            guard let custom = scratchSettings(style: style) else { print("bad --style: \(style)"); return 1 }
            source = custom
        }
        let appearance = source.overlayAppearance
        let mode = source.overlayMode
        let overlay = OverlayController(offscreen: true)
        overlay.apply(appearance)
        overlay.setOverlayMode(mode)
        overlay.disableFade()
        if calibration {
            let plan = CalibrationPlan.make(windows: windows.map { ($0.id, $0.targetPointCG) }, screensCG: Screens.framesCG)
            let n = plan.points.count
            let states: [CalibrationDotState] = (0..<n).map { i in
                i < min(2, n - 1) ? .done : (i == min(2, n - 1) ? .active : (i == n - 1 && n > 4 ? .skipped : .pending))
            }
            overlay.setMode(.calibrating)
            overlay.update(calibration: Array(zip(plan.points.map(\.pointCG), states)), progress: 0.45)
            let active = plan.points[min(2, max(0, n - 1))].pointCG
            overlay.showBanner("\(CalibrationController.instruction(dotColor: appearance.dotColor)) · Esc to cancel\nPoint 3 of \(n) · Return captures now",
                               near: active)
            print("calibration scene: \(n) points (\(plan.points.filter { $0.windowID != nil }.count) windows)")
        } else {
            overlay.setMode(.tracking)
            overlay.update(windows: windows)
            let current = windows.first, pending = windows.dropFirst().first
            overlay.update(current: current?.id, pending: pending?.id, progress: pending == nil ? nil : 0.6)
            if let anchor = pending ?? current {
                overlay.update(pointer: CGPoint(x: anchor.targetPointCG.x + 90, y: anchor.targetPointCG.y - 60))
            }
            // A status note, so Hidden mode's render shows only what Hidden draws.
            overlay.showBanner("AirFocus overlay preview · \(windows.count) window(s)", near: current?.targetPointCG, status: true)
            overlay.setPointerOnly(pointerOnly)
            if pointerOnly { overlay.update(pick: pending?.frameCG, progress: pending == nil ? nil : 0.6) }
            if recenterCue, let current { overlay.showRecenterCue(at: current.targetPointCG, progress: 0.6) }
        }
        guard let rep = overlay.snapshot(screen: 0, referenceFrames: windows.map(\.frameCG)),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); return 1
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("write failed: \(error)"); return 1 }
        print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh) pt, overlay \(mode.rawValue))")
        if calibration { return 0 }
        if pointerOnly { return checkMissionControl(overlay, windows: windows) }
        if mode == .hidden { return checkHidden(overlay, rep: rep, windows: windows, cue: recenterCue ? windows.first : nil) }
        return checkLayout(overlay, rep: rep, windows: windows)
    }

    /// Hidden mode while tracking: no dot, border, ring or pointer, and no pixel drawn except the
    /// recenter cue's when asked for. The background and the grey reference outlines don't count.
    private static func checkHidden(_ overlay: OverlayController, rep: NSBitmapImageRep, windows: [TrackedWindow],
                                    cue: TrackedWindow?) -> Int32 {
        guard let layout = overlay.layout(screen: 0) else { return 1 }
        var failures = 0
        print("\nhidden-mode check:")
        func expect(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        expect(layout.dots.isEmpty, "no window dots (\(layout.dots.count) drawn)")
        expect(layout.current == nil, "no focused border")
        expect(layout.pending == nil, "no pending border")
        expect(!layout.pointer, "no head pointer")
        expect(layout.cue == (cue != nil), cue == nil ? "no recenter cue" : "the recenter cue is up")
        // Every pixel other than the background and the reference outlines must belong to the cue.
        // The background is whatever the corner holds; outlines may only sit on a window's edge.
        let h = Screens.primaryHeight
        let cueCentre = cue.map { Geometry.localPoint(fromCG: $0.targetPointCG, panelOrigin: layout.panelOrigin, primaryHeight: h) }
        let cueRadius = overlay.appearance.ringRadius + 6
        let outlines = windows.map { Geometry.localRect(fromCG: $0.frameCG, panelOrigin: layout.panelOrigin, primaryHeight: h) }
        func onOutline(_ p: CGPoint) -> Bool {
            outlines.contains { r in
                r.insetBy(dx: -2, dy: -2).contains(p) && !r.insetBy(dx: 2, dy: 2).contains(p)
            }
        }
        guard let background = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return 1 }
        var stray = 0, inCue = 0
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let same = abs(c.redComponent - background.redComponent) < 0.01 && abs(c.greenComponent - background.greenComponent) < 0.01
                    && abs(c.blueComponent - background.blueComponent) < 0.01
                if same { continue }
                let local = CGPoint(x: x, y: rep.pixelsHigh - 1 - y)
                if let centre = cueCentre, Geometry.distance(local, centre) <= cueRadius { inCue += 1 }
                else if !onOutline(local) { stray += 1 }
            }
        }
        expect(stray == 0, "nothing else drawn (\(stray) stray pixel(s) sampled)")
        if cue != nil { expect(inCue > 0, "the cue has pixels (\(inCue) sampled)") }
        print(failures == 0 ? "hidden-mode check passed" : "hidden-mode check FAILED: \(failures) problem(s)")
        return failures == 0 ? 0 : 2
    }

    /// Mission Control, in either mode: the pointer and the held thumbnail's highlight show, nothing else.
    private static func checkMissionControl(_ overlay: OverlayController, windows: [TrackedWindow]) -> Int32 {
        guard let layout = overlay.layout(screen: 0) else { return 1 }
        var failures = 0
        print("\nMission Control check (overlay \(overlay.overlayMode.rawValue)):")
        func expect(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        expect(layout.pointer == overlay.appearance.showPointer, "the head pointer is \(overlay.appearance.showPointer ? "drawn" : "off by its toggle")")
        expect(layout.dots.isEmpty, "no window dots")
        expect(layout.current == nil, "no focused border")
        if windows.count > 1, overlay.appearance.showBorder { expect(layout.pending != nil, "the held thumbnail is highlighted") }
        print(failures == 0 ? "Mission Control check passed" : "Mission Control check FAILED: \(failures) problem(s)")
        return failures == 0 ? 0 : 2
    }

    /// The real Settings window, built but never ordered in, against a fake backend and scratch
    /// settings. Layout and text only: glass needs the window server to composite it.
    private static func renderSettings(to path: String, section: SettingsSection, dark: Bool, visual: SettingsVisual, style: String?) -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let settings = scratchSettings(style: style) else { print("bad --style: \(style ?? "")"); return 1 }
        let controller = SettingsWindowController(backend: OffscreenSettingsBackend(settings: settings))
        weak var releasedWindow: NSWindow?
        weak var releasedHosting: NSView?
        let drawn: Int32 = autoreleasepool {
            let window = controller.makeWindow(section: section, visual: visual)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            releasedWindow = window
            releasedHosting = window.contentView
            guard let view = window.contentView else { print("no content view"); return 1 }
            // SwiftUI builds on the first layout and settles over the next few run-loop passes.
            for _ in 0..<4 {
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2,
                                             pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                print("render failed"); return 1
            }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return 1 }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("write failed: \(error)"); return 1 }
            print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh) px, \(section.rawValue), \(dark ? "dark" : "light"))")
            window.close()
            return 0
        }
        guard drawn == 0 else { return drawn }
        // Closing has to free the window and its content, as it does in the app.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let released = releasedWindow == nil && releasedHosting == nil && !controller.isOpen
        print("window and hosting view released after close: \(released ? "yes" : "NO")")
        return released ? 0 : 3
    }

    /// Every state, at actual size and 8×, on light and dark menu bars, next to system symbols for
    /// comparison. The 8× is the real pixels enlarged, so any softness shows.
    private static func renderMenuBarIcons(to directory: String) -> Int32 {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            print("cannot create \(directory): \(error)"); return 1
        }
        if !MenuBarIcon.hasArt { print("note: \(MenuBarIcon.resourceName).png is not in this bundle: these are the SF Symbol fallbacks") }
        let glyphs = MenuBarIcon.Glyph.allCases
        func write(_ rep: NSBitmapImageRep, _ name: String) -> Bool {
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: dir.appendingPathComponent(name))) != nil
        }
        func canvas(_ w: Int, _ h: Int, scale: Int, _ draw: @MainActor () -> Void) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = NSSize(width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .none
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        let cell = 26, strip = 26, big = 144, gap = 8, neighbours = ["magnifyingglass", "wifi", "battery.100percent", "airpodspro"]
        let width = max(glyphs.count * (big + gap), (glyphs.count + neighbours.count + 1) * cell) + gap
        let height = 2 * strip + 2 * big + 4 * gap
        let sheet = canvas(width, height, scale: 2) {
            NSColor(white: 0.5, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var y = height - gap
            for dark in [false, true] {
                let bar = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)
                let ink: NSColor = dark ? .white : .black
                y -= strip
                bar.setFill()
                NSRect(x: gap, y: y, width: width - 2 * gap, height: strip).fill()
                var x = gap + 6
                func place(_ image: NSImage) {
                    let s = image.size
                    drawTinted(image, ink, in: NSRect(x: CGFloat(x) + (CGFloat(cell) - s.width) / 2, y: CGFloat(y) + (CGFloat(strip) - s.height) / 2, width: s.width, height: s.height))
                    x += cell
                }
                for g in glyphs { if let image = MenuBarIcon.image(g, description: g.rawValue) { place(image) } }
                x += cell
                for n in neighbours {
                    if let s = NSImage(systemSymbolName: n, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) { place(s) }
                }
            }
            for dark in [false, true] {
                y -= gap + big
                var x = gap
                for g in glyphs {
                    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(x: x, y: y, width: big, height: big).fill()
                    if let image = MenuBarIcon.image(g, description: g.rawValue) {
                        let scaledW = image.size.width * 8
                        // 8× the point size at 2 px per point: 4× nearest-neighbour on the 2x bitmap.
                        drawTinted(image, dark ? .white : .black, in: NSRect(x: CGFloat(x) + (CGFloat(big) - scaledW) / 2, y: CGFloat(y), width: scaledW, height: 144))
                    }
                    x += big + gap
                }
            }
        }
        var ok = sheet.map { write($0, "menubar-sheet.png") } ?? false
        for g in glyphs {
            guard let image = MenuBarIcon.image(g, description: g.rawValue) else { ok = false; continue }
            for (dark, tag) in [(false, "light"), (true, "dark")] {
                let s = image.size
                let ink: NSColor = dark ? .white : .black
                let bar = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)
                for (factor, label) in [(1, "actual"), (8, "8x")] {
                    let w = Int(s.width) * factor + 8 * factor, h = Int(s.height) * factor + 8 * factor
                    let rep = canvas(w, h, scale: 2) {
                        bar.setFill()
                        NSRect(x: 0, y: 0, width: w, height: h).fill()
                        drawTinted(image, ink, in: NSRect(x: CGFloat(4 * factor), y: CGFloat(4 * factor), width: s.width * CGFloat(factor), height: s.height * CGFloat(factor)))
                    }
                    if let rep { ok = write(rep, "menubar-\(g.rawValue)-\(tag)-\(label).png") && ok } else { ok = false }
                }
            }
        }
        print(ok ? "wrote menu bar icons to \(directory)" : "some menu bar icons failed to render")
        return ok ? 0 : 1
    }

    /// Numeric check of the tracking render: every dot sits on its window's visible centre and has
    /// the chosen colour in the rendered pixels, and the borders match the window frames, or are
    /// absent when turned off. Primary screen only.
    private static func checkLayout(_ overlay: OverlayController, rep: NSBitmapImageRep, windows: [TrackedWindow]) -> Int32 {
        guard let layout = overlay.layout(screen: 0) else { return 1 }
        let appearance = overlay.appearance
        let primary = Screens.framesCG.first ?? .zero
        let h = Screens.primaryHeight
        var failures = 0
        var maxDelta = 0.0
        print("\nlayout check (panel-local points, origin bottom-left):")
        if !appearance.showDots && !layout.dots.isEmpty { print("  FAIL dots are off but \(layout.dots.count) drawn"); failures += 1 }
        let wantDot = NSColor(cgColor: appearance.dotColor.cgColor)?.usingColorSpace(.deviceRGB)
        for w in windows where appearance.showDots && primary.contains(w.targetPointCG) {
            let want = Geometry.localPoint(fromCG: w.targetPointCG, panelOrigin: layout.panelOrigin, primaryHeight: h)
            guard let got = layout.dots[w.id] else { print("  FAIL wid \(w.id): no dot layer"); failures += 1; continue }
            let delta = Geometry.distance(want, got)
            maxDelta = max(maxDelta, delta)
            let px = rep.colorAt(x: Int(want.x), y: rep.pixelsHigh - 1 - Int(want.y))?.usingColorSpace(.deviceRGB)
            let close = { (a: CGFloat?, b: CGFloat?) in abs((a ?? -1) - (b ?? -2)) < 0.1 }
            let colored = close(px?.redComponent, wantDot?.redComponent) && close(px?.greenComponent, wantDot?.greenComponent)
                && close(px?.blueComponent, wantDot?.blueComponent)
            let ok = delta < 0.5 && colored
            if !ok { failures += 1 }
            print(String(format: "  %@ wid %-6u %-8@ dot want (%.1f, %.1f) got (%.1f, %.1f) Δ %.2f pt, pixel %@",
                         ok ? "ok  " : "FAIL", w.id, w.appName as NSString, want.x, want.y, got.x, got.y, delta,
                         colored ? "right colour" : "WRONG colour"))
        }
        func checkBorder(_ label: String, _ id: CGWindowID?, _ got: CGRect?) {
            guard let id, let w = windows.first(where: { $0.id == id }) else { return }
            guard appearance.showBorder else {
                if got != nil { print("  FAIL \(label) border is off but drawn"); failures += 1 }
                return
            }
            let inset = appearance.borderWidth / 2
            let want = Geometry.localRect(fromCG: w.frameCG, panelOrigin: layout.panelOrigin, primaryHeight: h).insetBy(dx: inset, dy: inset)
            guard let got else { print("  FAIL \(label) border missing"); failures += 1; return }
            let d = max(abs(got.minX - want.minX), abs(got.minY - want.minY), abs(got.maxX - want.maxX), abs(got.maxY - want.maxY))
            if d >= 0.5 { failures += 1 }
            print(String(format: "  %@ %@ border on wid %u: want %@ got %@ (max Δ %.2f pt)", d < 0.5 ? "ok  " : "FAIL",
                         label as NSString, id, NSStringFromRect(want), NSStringFromRect(got), d))
        }
        checkBorder("current", windows.first?.id, layout.current)
        checkBorder("pending", windows.dropFirst().first?.id, layout.pending)
        print(failures == 0 ? String(format: "layout check passed (max dot Δ %.2f pt)", maxDelta)
                            : "layout check FAILED: \(failures) problem(s)")
        return failures == 0 ? 0 : 2
    }

    /// Dots on every tracked window, the frontmost highlighted, a pending second window with a
    /// progress ring, a sample head pointer and a banner, on the real screen, for checking by eye.
    private static func overlayPreview(seconds: Double) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let windows = WindowEnumerator().snapshot().windows
        let overlay = OverlayController()
        overlay.disableFade()
        overlay.setMode(.tracking)
        overlay.update(windows: windows)
        let current = windows.first
        let pending = windows.dropFirst().first
        overlay.update(current: current?.id, pending: pending?.id, progress: pending == nil ? nil : 0.6)
        if let anchor = pending ?? current {
            overlay.update(pointer: CGPoint(x: anchor.targetPointCG.x + 90, y: anchor.targetPointCG.y - 60))
        }
        overlay.showBanner("AirFocus overlay preview · \(windows.count) window(s) · closes in \(Int(seconds)) s",
                           style: .info, near: current?.targetPointCG)
        print("overlay preview: \(windows.count) window(s); current = \(current.map { "\($0.appName) \($0.id)" } ?? "none"), "
              + "pending = \(pending.map { "\($0.appName) \($0.id)" } ?? "none")")
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                overlay.setMode(.hidden)
                overlay.hideBanner()
                NSApp.stop(nil)
                // stop() takes effect after the next event; post a dummy one so run() returns now.
                if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(e, atStart: true)
                }
            }
        }
        app.run()
        return 0
    }
}

/// Draws a template image in one colour, as the menu bar would.
private func drawTinted(_ image: NSImage, _ color: NSColor, in rect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
    image.draw(in: rect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(color.cgColor)
    ctx.fill(rect)
    ctx.endTransparencyLayer()
}

/// The Settings window's backend for --render-settings: sample status, and no actions, since
/// nothing can be clicked offscreen.
@MainActor
private final class OffscreenSettingsBackend: SettingsBackend {
    let settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }

    func settingsChanged() {}
    func settingsStatus() -> SettingsStatus {
        var s = SettingsStatus()
        s.tracking = "On"
        s.airPods = "connected · output: AirPods Pro"
        s.sampleRate = "50 Hz"
        s.calibration = "calibrated (8 points, error 1.2°), good"
        s.hasCalibration = true
        s.canRecenter = true
        s.screenLock = "locks immediately"
        return s
    }
    func launchAtLoginState() -> LaunchAtLoginState { LaunchAtLoginState() }
    func settingsWindowOpenChanged(_ open: Bool) {}
    func settingsKeyChanged(_ key: Bool) {}
    func calibrate() {}
    func resetAndRecalibrate() {}
    func recenterFromSettings() {}
    func setLaunchAtLogin(_ on: Bool) {}
    func openLoginItemsSettings() {}
    func openLockScreenSettings() {}
}

/// The diagnostics text shared by --diagnose and Developer › Copy Diagnostics.
@MainActor
enum Diagnostics {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func report(includeHotkeyProbe: Bool = false, runtime: [String] = []) -> String {
        var out: [String] = []
        func section(_ title: String) { out.append(""); out.append("== \(title)") }
        out.append("AirFocus \(version) diagnostics, \(ISO8601DateFormatter().string(from: Date()))")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(ProcessInfo.processInfo.operatingSystemVersionString))")
        out.append("bundle: \(Bundle.main.bundlePath)")
        let fromTerminal = getppid() != 1
        if fromTerminal {
            out.append("note: started from a terminal, so TCC attributes Accessibility/Motion below to the terminal app, not AirFocus.")
        }

        section("Motion")
        let mm = CMHeadphoneMotionManager()
        out.append("headphone motion available on this Mac: \(mm.isDeviceMotionAvailable)")
        out.append("Motion & Fitness authorization: \(CMHeadphoneMotionManager.authorizationStatus().label)")

        section("Audio")
        if let d = AudioRoute.defaultOutput() {
            out.append("default output: \(d.name) (\(d.transportName))")
        } else {
            out.append("default output: none")
        }
        let candidates = AudioRoute.headphoneCandidates()
        out.append("AirPods/Beats outputs present: " + (candidates.isEmpty ? "none" : candidates.map(\.name).joined(separator: ", ")))

        section("Permissions")
        out.append("Accessibility trusted: \(AX.isTrusted)")
        out.append("Screen Recording: not used, never requested")

        section("Screen lock")
        out.append("require password after screen saver: \(ScreenLockSetting.read().menuText) (sysadminctl -screenLock status)")
        out.append("screen locked now: \(ScreenSaverControl.isScreenLocked); screen saver running: \(ScreenSaverControl.isScreenSaverRunning)")
        out.append("on AC power: \(ScreenSaverControl.onACPower)")

        section("Head flicks")
        let flickSettings = AppSettings()
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        out.append("flick up (Mission Control): \(flickSettings.flickUpEnabled ? "on" : "off")")
        out.append("flick left/right (Desktops): \(flickSettings.flickSidewaysEnabled ? "on" : "off"); "
                   + "system shortcuts: left \(DesktopShortcut.resolve(hotkeys, left: true) == nil ? "off" : "on"), "
                   + "right \(DesktopShortcut.resolve(hotkeys, left: false) == nil ? "off" : "on")")
        out.append(String(format: "flick strength: %.2f", flickSettings.flickSensitivity))

        section("Window management")
        out.append("Stage Manager: \(Screens.stageManagerEnabled ? "on" : "off")")
        if includeHotkeyProbe {
            out.append("plain Esc/Return hotkeys registrable (calibration keys): \(HotKeys.probePlainKeys())")
        }

        section("Private symbols (dlsym)")
        for (name, ok) in PrivateAPI.report { out.append("\(ok ? "ok     " : "MISSING") \(name)") }

        section("Screens")
        let h = Screens.primaryHeight
        for (i, s) in NSScreen.screens.enumerated() {
            let cg = Geometry.cgRect(fromAppKit: s.frame, primaryHeight: h)
            out.append("[\(i)] display \(s.displayID) \(s.localizedName): AppKit \(fmt(s.frame)), CG \(fmt(cg)), scale \(s.backingScaleFactor)\(i == 0 ? " (primary)" : "")")
        }
        let config = Screens.configuration
        out.append("display configuration key: \(config.key)")

        section("Calibration")
        let store = CalibrationStore(defaults: .standard)   // the bundle's own domain, also from the CLI
        for (label, key) in [("AirPods", config.key), ("mouse simulation", AppController.simulationKeyPrefix + config.key)] {
            if let c = store.load(displayKey: key) {
                out.append("\(label): \(c.summary), rms \(String(format: "%.0f", c.rmsErrorPoints)) pt, \(c.anchors.count) window anchors, \(c.createdAt)")
            } else {
                out.append("\(label): not calibrated for this display configuration")
            }
        }
        let others = store.storedKeys.filter { $0 != config.key && $0 != AppController.simulationKeyPrefix + config.key }
        if !others.isEmpty { out.append("other stored configurations: \(others.count)") }

        if !runtime.isEmpty {
            section("Runtime")
            out.append(contentsOf: runtime)
        }
        out.append("")
        out.append("log: \(Log.fileURL.path)")
        return out.joined(separator: "\n")
    }

    private static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY))) \(Int(r.width))×\(Int(r.height))"
    }
}
