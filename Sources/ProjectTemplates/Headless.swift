import AppKit
import SwiftUI

/// A launch by `creatoros` or the MCP server (`--headless`) runs as a background service: the control socket answers,
/// and there is no window, no Dock tile and no update prompt. The app turns into the ordinary windowed app the moment a
/// window is wanted: a command with --show, a reopen from the Dock, Spotlight or Finder, or anything that activates it.
/// A headless copy nobody has used for `idleLimit` quits by itself, so it never lingers.
@MainActor final class Headless {
    static let shared = Headless()
    /// `--headless` asks for it; `--show` (a test run that wants its window) wins.
    private(set) var active = CommandLine.arguments.contains("--headless") && !CommandLine.arguments.contains("--show")
    /// Ten minutes; `--idle-quit SECONDS` shortens it for checks.
    let idleLimit: TimeInterval = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--idle-quit"), arguments.indices.contains(index + 1),
              let seconds = TimeInterval(arguments[index + 1]), seconds > 0 else { return 600 }
        return seconds
    }()
    /// The main window, kept transparent and off screen while headless so revealing it is instant.
    weak var mainWindow: NSWindow?
    /// Whether quitting now would interrupt nothing; the model answers it.
    var canQuit: @MainActor () -> Bool = { true }
    private var lastUse = Date()
    private var timer: Timer?
    private var activeObserver: Any?

    /// From the App's init, before any window exists.
    func start() {
        guard active, timer == nil else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        // `open -g` never activates the app, so activation means a person (or --show) wants it.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Headless.shared.promote() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: min(30, idleLimit), repeats: true) { _ in MainActor.assumeIsolated { Headless.shared.quitIfIdle() } }
    }
    /// A control request arrived: the idle clock starts again.
    func touch() { lastUse = Date() }
    /// Become the ordinary app: Dock tile, menu bar, update checks. The main window comes back too, unless another
    /// window is already on screen, so the app is never visible with nothing to show.
    func promote() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        NSApp.setActivationPolicy(.regular)
        Updates.shared.resume()
        guard let window = mainWindow else { return }
        window.alphaValue = 1; window.ignoresMouseEvents = false
        if !NSApp.windows.contains(where: \.isVisible) { window.makeKeyAndOrderFront(nil) }
    }
    /// Promote and bring the main window forward: --show, or a reopen from the Dock, Spotlight or Finder.
    func reveal() {
        promote()
        mainWindow?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
    private func quitIfIdle() {
        guard active, Date().timeIntervalSince(lastUse) >= idleLimit, !NSApp.windows.contains(where: \.isVisible), canQuit() else { return }
        NSApp.terminate(nil)
    }
}

/// Placed behind the main window's content. While headless it makes the window transparent and click-through before it
/// is first drawn and then takes it off screen, so not even a frame of it shows; it also remembers the window for
/// `Headless.reveal()`.
struct HeadlessWindowHider: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                guard Headless.shared.mainWindow == nil else { return }
                Headless.shared.mainWindow = window
                guard Headless.shared.active else { return }
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                // SwiftUI orders the window front later in the same launch pass; take it away again after that.
                DispatchQueue.main.async { if Headless.shared.active { window.orderOut(nil) } }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}
}
