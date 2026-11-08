import AppKit

// CLI diagnostics (spec §3.2) print and exit without the menu bar UI.
if let mode = MainActor.assumeIsolated({ CLI.mode(from: CommandLine.arguments) }) {
    let code = MainActor.assumeIsolated { CLI.run(mode) }
    exit(code)
}

// The menu bar app. LSUIElement is set in Info.plist; the activation policy is set here as well
// so a bare binary behaves the same (R§7.1). Launch it with `open`, not from a terminal, so TCC
// attributes Accessibility and Motion to AirFocus rather than to the terminal (R§7.4).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
