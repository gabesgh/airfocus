import AppKit
import SwiftUI
import AirFocusCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case tracking, appearance, lookAway, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracking: return "Tracking"
        case .appearance: return "Appearance"
        case .lookAway: return "Look Away"
        case .general: return "General"
        }
    }

    /// The window is only as tall as the section needs.
    var height: CGFloat {
        switch self {
        case .tracking: return 610
        case .appearance: return 802
        case .lookAway: return 372
        case .general: return 612
        }
    }

    var offersRestoreDefaults: Bool { self == .tracking || self == .appearance }
}

/// The accessibility state the custom surfaces follow. System controls and glass adapt on their own.
struct SettingsVisual: Equatable {
    var reduceTransparency = false
    var increaseContrast = false
}

extension EnvironmentValues {
    @Entry var settingsVisual = SettingsVisual()
}

/// The window's content. Native segmented control for navigation, grouped cards for content, and
/// Liquid Glass only on the buttons and the preview caption, which float over the backdrop.
struct SettingsRootView: View {
    let model: SettingsModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var visual: SettingsVisual {
        SettingsVisual(reduceTransparency: reduceTransparency || model.forcedVisual.reduceTransparency,
                       increaseContrast: contrast == .increased || model.forcedVisual.increaseContrast)
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            SettingsBackdrop()
            VStack(spacing: 0) {
                // Sits in the titlebar's band, clear of the traffic lights.
                Picker("Section", selection: $model.section) {
                    ForEach(SettingsSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 356)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)

                Group {
                    switch model.section {
                    case .tracking: TrackingSection(model: model)
                    case .appearance: AppearanceSection(model: model)
                    case .lookAway: LookAwaySection(model: model)
                    case .general: GeneralSection(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if model.section.offersRestoreDefaults {
                    RestoreDefaultsBar(model: model)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
        .environment(\.settingsVisual, visual)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Something for the glass to refract: the window background with a hint of the accent colour.
private struct SettingsBackdrop: View {
    @Environment(\.settingsVisual) private var visual
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !visual.reduceTransparency {
                LinearGradient(colors: [Color.accentColor.opacity(scheme == .dark ? 0.20 : 0.13), .clear,
                                        Color.accentColor.opacity(scheme == .dark ? 0.08 : 0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: Building blocks

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.settingsVisual) private var visual
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)
                .opacity(visual.reduceTransparency || visual.increaseContrast ? 1 : (scheme == .dark ? 0.55 : 0.72)), in: shape)
            .overlay(shape.strokeBorder(visual.increaseContrast ? Color.primary.opacity(0.55) : Color(nsColor: .separatorColor),
                                        lineWidth: visual.increaseContrast ? 1 : 0.5))
    }
}

/// A title, a one-line plain explanation and a control on the right.
private struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!enabled)
        }
    }
}

private struct RestoreDefaultsBar: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Resets sensitivity and overlay styling. Overlay mode and calibration stay.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            GlassEffectContainer {
                Button { model.restoreDefaults() } label: { Text("Restore Defaults").foregroundStyle(Color(nsColor: .labelColor)) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }
}

private struct SectionScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: Tracking

private struct TrackingSection: View {
    let model: SettingsModel

    var body: some View {
        SectionScroll {
            SettingsCard {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sensitivity").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(model.tuning.readout)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: model.sensitivity, in: 0...1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Calm").font(.system(size: 11))
                } maximumValueLabel: {
                    Text("Snappy").font(.system(size: 11))
                }
                .labelsHidden()
                Text("Calm waits longer and needs a steadier head before it switches. Snappy reacts sooner and smooths the pointer less. Typing always holds switching.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard {
                Text("Focus mode").font(.system(size: 13, weight: .medium))
                Picker("Focus mode", selection: model.binding(\.focusMode)) {
                    Text("Automatic").tag(FocusMode.automatic)
                    Text("Hotkey only").tag(FocusMode.hotkeyOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.binding(\.focusMode).wrappedValue == .automatic
                     ? "Holding your head on a window focuses it. ⌃⌥⌘F focuses it right away."
                     : "Nothing switches by itself. ⌃⌥⌘F focuses the window you face.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            SettingsCard {
                ToggleRow(title: "Flick up for Mission Control",
                          detail: "A sharp flick up from screen height. Flick up again to close it.",
                          isOn: model.binding(\.flickUpEnabled))
                Divider()
                ToggleRow(title: "Hold on a window in Mission Control to pick it",
                          detail: "Hold the pointer on a window for about a second to bring it forward and close Mission Control. Using the mouse holds this off.",
                          isOn: model.binding(\.missionControlPick))
                Divider()
                ToggleRow(title: "Flick left or right to change Desktop",
                          detail: "A sharp flick that starts while you're facing the screen. If the menu bar icon shows the pause badge, recenter first.",
                          isOn: model.binding(\.flickSidewaysEnabled))
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flick strength").font(.system(size: 13, weight: .medium))
                    Slider(value: model.stepped(\.flickSensitivity, step: 0.05), in: 0...1) {
                        Text("Flick strength")
                    } minimumValueLabel: {
                        Text("Firm").font(.system(size: 11))
                    } maximumValueLabel: {
                        Text("Light").font(.system(size: 11))
                    }
                    .labelsHidden()
                    Text("Firm needs a sharper flick, so normal head movement is less likely to set one off. Light is easier to do but easier to set off by accident.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Automatic switching holds while this window is in front, so your head can't pull focus away from it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: Appearance

private struct AppearanceSection: View {
    let model: SettingsModel

    var body: some View {
        let a = model.appearance
        let mode = model.binding(\.overlayMode)
        let hidden = mode.wrappedValue == .hidden
        VStack(spacing: 8) {
            SettingsCard {
                HStack(alignment: .center, spacing: 12) {
                    Text("Overlay").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Picker("Overlay", selection: mode) {
                        Text("Hidden").tag(OverlayMode.hidden)
                        Text("Visible").tag(OverlayMode.visible)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                Text(hidden
                     ? "Nothing draws while you work. ⌃⌥⌘R shows the focused window's dot for a second, and Mission Control keeps its pointer."
                     : "Window dots, the focus border and the head pointer show while tracking, styled as below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            OverlayPreviewPanel(appearance: a, caption: hidden ? "Preview of Visible" : "Live preview")
                .padding(.horizontal, 16)
            SectionScroll {
                Text(hidden ? "These apply when the overlay is Visible, and to Mission Control's pointer."
                            : "Also used for Mission Control's pointer, and in Hidden mode for the ⌃⌥⌘R dot.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                SettingsCard {
                    ToggleRow(title: "Window dots", detail: "The mark in the middle of each window, to aim your nose at.",
                              isOn: model.binding(\.showWindowDots))
                    StyleControls(color: model.binding(\.dotColor), colorName: "Dot colour",
                                  size: model.stepped(\.dotSize, step: 1), sizeName: "Size", range: SettingsDefault.dotSizeRange)
                        .disabled(!a.showDots)
                }
                SettingsCard {
                    ToggleRow(title: "Focused window border",
                              detail: "Outlines the focused window, and dashes the one you're about to switch to.",
                              isOn: model.binding(\.showFocusBorder))
                    StyleControls(color: model.binding(\.borderColor), colorName: "Border colour",
                                  size: model.stepped(\.borderWidth, step: 0.5), sizeName: "Width", range: SettingsDefault.borderWidthRange)
                        .disabled(!a.showBorder)
                }
                SettingsCard {
                    ToggleRow(title: "Head pointer", detail: "The mark that follows your head and shows where it points.",
                              isOn: model.binding(\.showHeadPointer))
                    Picker("Pointer shape", selection: model.binding(\.pointerShape)) {
                        ForEach(PointerShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!a.showPointer)
                    StyleControls(color: model.binding(\.pointerColor), colorName: "Pointer colour",
                                  size: model.stepped(\.pointerSize, step: 1), sizeName: "Size", range: SettingsDefault.pointerSizeRange)
                        .disabled(!a.showPointer)
                }
                SettingsCard {
                    ToggleRow(title: "Switch progress ring",
                              detail: "The white circle that fills around a dot before a switch. Timing doesn't change.",
                              isOn: model.binding(\.showProgressRing))
                    Divider()
                    ToggleRow(title: "Status banners",
                              detail: "Notes like “Recentered”. Calibration, permission and errors always show.",
                              isOn: model.binding(\.showStatusBanners))
                }
            }
        }
    }
}

/// A colour well with a "follow the system accent" checkbox, and optionally a size slider.
private struct StyleControls: View {
    @Binding var color: StyleColor
    let colorName: String
    var size: Binding<Double>?
    var sizeName = ""
    var range: ClosedRange<Double> = 0...1
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker(colorName, selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            Toggle("Accent", isOn: accentBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Follow the system accent colour")
            Spacer(minLength: 8)
            if let size {
                HStack(spacing: 10) {
                    Text(sizeName).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    Slider(value: size, in: range) { Text(sizeName) }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 130)
                    Text(String(format: "%g pt", size.wrappedValue))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .opacity(isEnabled ? 1 : 0.45)
            }
        }
    }

    private var resolved: NSColor {
        color.followsAccent ? .controlAccentColor
            : NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func style(from nsColor: NSColor) -> StyleColor? {
        nsColor.usingColorSpace(.sRGB).map {
            StyleColor(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent))
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: resolved) }, set: { new in
            guard let picked = Self.style(from: NSColor(new)) else { return }
            // The well echoes its current colour when the panel opens: that isn't a choice.
            if picked != Self.style(from: resolved) { color = picked }
        })
    }

    private var accentBinding: Binding<Bool> {
        Binding(get: { color.followsAccent }, set: { on in
            color = on ? .accent : (Self.style(from: resolved) ?? .white)
        })
    }
}

/// A miniature desktop drawn by the same OverlayCanvas as the real overlay, so what it shows is
/// what the overlay draws, at real size and in real colours. Static: nothing runs while it is idle.
private struct OverlayPreviewPanel: View {
    let appearance: OverlayAppearance
    var caption = "Live preview"
    @Environment(\.settingsVisual) private var visual

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            MockDesktop()
            OverlayPreviewCanvas(appearance: appearance)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
        }
        .frame(width: PreviewScene.size.width, height: PreviewScene.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(visual.increaseContrast ? Color.primary.opacity(0.55) : Color(nsColor: .separatorColor),
                                    lineWidth: visual.increaseContrast ? 1 : 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the overlay on a miniature desktop")
    }
}

/// The preview's mock windows, in the overlay's top-left-origin coordinates.
enum PreviewScene {
    static let size = CGSize(width: 528, height: 168)
    static let focused = TrackedWindow(id: 1, frameCG: CGRect(x: 16, y: 14, width: 222, height: 110))
    static let pending = TrackedWindow(id: 2, frameCG: CGRect(x: 256, y: 14, width: 256, height: 76))
    static let other = TrackedWindow(id: 3, frameCG: CGRect(x: 256, y: 100, width: 256, height: 54))
    static let pointer = CGPoint(x: pending.targetPointCG.x + 66, y: pending.targetPointCG.y + 10)
    static let progress = 0.6
}

private struct MockDesktop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: scheme == .dark
                           ? [Color(red: 0.13, green: 0.17, blue: 0.33), Color(red: 0.30, green: 0.16, blue: 0.36)]
                           : [Color(red: 0.55, green: 0.72, blue: 0.93), Color(red: 0.80, green: 0.66, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach([PreviewScene.focused, PreviewScene.pending, PreviewScene.other], id: \.id) { window in
                MockWindow()
                    .frame(width: window.frameCG.width, height: window.frameCG.height)
                    .offset(x: window.frameCG.minX, y: window.frameCG.minY)
            }
        }
    }
}

private struct MockWindow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OverlayStyle.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.primary.opacity(0.22)).frame(width: 6, height: 6)
                }
            }
            ForEach(0..<2, id: \.self) { i in
                Capsule().fill(Color.primary.opacity(0.13)).frame(width: i == 0 ? 96 : 66, height: 4)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Mid-toned enough in light mode for the default white dot to read as white.
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.86), in: shape)
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }
}

private struct OverlayPreviewCanvas: NSViewRepresentable {
    let appearance: OverlayAppearance

    func makeNSView(context: Context) -> OverlayCanvas {
        let canvas = OverlayCanvas(frame: CGRect(origin: .zero, size: PreviewScene.size))
        canvas.primaryHeight = PreviewScene.size.height
        return canvas
    }

    func updateNSView(_ canvas: OverlayCanvas, context: Context) {
        let a = appearance
        canvas.apply(a)
        canvas.setDots([PreviewScene.focused, PreviewScene.pending, PreviewScene.other], visible: a.showDots)
        canvas.setCurrent(frameCG: a.showBorder ? PreviewScene.focused.frameCG : nil, faded: false, animateFade: false)
        canvas.setPending(frameCG: a.showBorder ? PreviewScene.pending.frameCG : nil, dotCG: PreviewScene.pending.targetPointCG,
                          progress: a.showRing ? PreviewScene.progress : nil)
        canvas.setPointer(a.showPointer ? PreviewScene.pointer : nil)
    }
}

// MARK: Look Away

private struct LookAwaySection: View {
    let model: SettingsModel

    var body: some View {
        let _ = model.revision
        let reason = model.status.lookAwayBlockReason
        SectionScroll {
            SettingsCard {
                ToggleRow(title: "Screen saver when I look away",
                          detail: reason.map { "Unavailable: \($0)." } ?? "Starts the screen saver when you clearly turn away from your screens.",
                          isOn: model.binding(\.lookAwayEnabled), enabled: reason == nil)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Delay").font(.system(size: 13, weight: .medium))
                    Picker("Delay", selection: model.binding(\.lookAwayDelay)) {
                        ForEach(SettingsDefault.lookAwayDelayChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("How long you have to stay turned away. Any key press, click or mouse move restarts it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            SettingsCard {
                ToggleRow(title: "Lock immediately",
                          detail: "Locks the Mac instead of only starting the screen saver. Uses a private API.",
                          isOn: model.binding(\.lockImmediately))
                Divider()
                ToggleRow(title: "Treat removing AirPods as away",
                          detail: "Taking your AirPods out for 10 s with no input counts as looking away.",
                          isOn: model.binding(\.treatRemovalAsAway))
            }
            SettingsCard {
                SettingRow(title: "Screen lock: \(model.status.screenLock)",
                           detail: "Set in System Settings › Lock Screen. AirFocus only reads it.") {
                    GlassEffectContainer {
                        Button { model.backend.openLockScreenSettings() } label: { Text("Open…").foregroundStyle(Color(nsColor: .labelColor)) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: General

private struct GeneralSection: View {
    let model: SettingsModel

    private static let hotkeys: [(String, String)] = [
        ("⌃⌥⌘T", "Start or stop tracking"),
        ("⌃⌥⌘C", "Calibrate or recalibrate"),
        ("⌃⌥⌘R", "Recenter on the focused window"),
        ("⌃⌥⌘F", "Focus the window you face"),
        ("Return", "During calibration: capture the dot now"),
        ("Esc", "During calibration: cancel"),
    ]

    var body: some View {
        let status = model.status
        let launch = model.launchState
        SectionScroll {
            SettingsCard {
                ToggleRow(title: "Launch at Login",
                          detail: launch.needsApproval
                              ? "Waiting for approval in System Settings › Login Items."
                              : "Start AirFocus when you log in.",
                          isOn: model.launchAtLogin)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Menu bar icon").font(.system(size: 13, weight: .medium))
                    Picker("Menu bar icon", selection: model.binding(\.menuBarIcon)) {
                        ForEach(MenuBarIconMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.binding(\.menuBarIcon).wrappedValue != .always {
                        Text("Open AirFocus again from Spotlight or the Applications folder to bring these settings back. The ⌃⌥⌘ hotkeys keep working.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if launch.needsApproval {
                    Button { model.backend.openLoginItemsSettings() } label: { Text("Open Login Items…").foregroundStyle(Color(nsColor: .labelColor)) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            SettingsCard {
                Text("Calibration").font(.system(size: 13, weight: .medium))
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(status.hasCalibration ? "Recalibrate…" : "Calibrate…") { model.backend.calibrate() }
                            .buttonStyle(.glassProminent)
                        Button { model.backend.resetAndRecalibrate() } label: { Text("Reset & Recalibrate").foregroundStyle(Color(nsColor: .labelColor)) }
                            .buttonStyle(.glass)
                        Button { model.backend.recenterFromSettings() } label: { Text("Recenter").foregroundStyle(Color(nsColor: .labelColor)) }
                            .buttonStyle(.glass)
                            .disabled(!status.canRecenter)
                    }
                }
                Text("Calibrating closes this window. Recenter waits 2 s so you can face the focused window first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard {
                Text("Status").font(.system(size: 13, weight: .medium))
                InfoGrid(rows: [("Tracking", status.tracking), ("AirPods", status.airPods),
                                ("Sample rate", status.sampleRate), ("Calibration", status.calibration)])
            }
            SettingsCard {
                Text("Hotkeys").font(.system(size: 13, weight: .medium))
                InfoGrid(rows: Self.hotkeys)
            }
        }
    }
}

private struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(row.1)
                        .font(.system(size: 12).monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
