import AppKit
import SwiftUI

/// `--agent-screen` (every real-app check) and app-hosted XCTest runs: nothing this copy shows can appear on any of
/// Junior's displays or take focus. Windows are still ordered in, so Accessibility and window lists still see them, but
/// every one, sheets, alerts and Settings included, is fully transparent and lets clicks through, and the app never
/// activates or gains a Dock tile. Video Prompter a28a30c, with TestOffscreen's swaps so no window shows for even one frame.
enum AgentScreen {
    static let active = CommandLine.arguments.contains("--agent-screen")
        || ProcessInfo.processInfo.environment["CREATOROS_AGENT_SCREEN"] == "1"
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// From the App's init, first, before any window exists.
    @MainActor static func install() {
        guard active else { return }
        NSWindow.keepEveryWindowInvisible()
        // Every way a window is put on screen hides it first, and alpha can never be raised again.
        swap(NSWindow.self, #selector(setter: NSWindow.alphaValue), #selector(NSWindow.agentScreen_setAlphaValue(_:)))
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.agentScreen_order(_:relativeTo:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.agentScreen_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.agentScreen_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.agentScreen_makeKeyAndOrderFront(_:)))
        swap(NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:"), #selector(NSApplication.agentScreen_activate(ignoringOtherApps:)))
        swap(NSApplication.self, NSSelectorFromString("activate"), #selector(NSApplication.agentScreen_activateNow))
    }
    private static func swap(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let old = class_getInstanceMethod(type, original), let new = class_getInstanceMethod(type, replacement) else { return }
        method_exchangeImplementations(old, new)
    }
}
extension NSWindow {
    /// Video Prompter a28a30c: the backstop for any window that reaches the screen another way.
    static func keepEveryWindowInvisible() {
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.alphaValue != 0 || !window.ignoresMouseEvents else { return }
            MainActor.assumeIsolated { window.alphaValue = 0; window.ignoresMouseEvents = true }
        }
    }
    // After AgentScreen.install swaps these in, each agentScreen_ call below runs AppKit's original.
    private func agentScreenHide() { agentScreen_setAlphaValue(0); ignoresMouseEvents = true }
    @objc func agentScreen_setAlphaValue(_ value: CGFloat) { agentScreen_setAlphaValue(0) }
    @objc func agentScreen_order(_ mode: NSWindow.OrderingMode, relativeTo other: Int) { agentScreenHide(); agentScreen_order(mode, relativeTo: other) }
    @objc func agentScreen_orderFront(_ sender: Any?) { agentScreenHide(); agentScreen_orderFront(sender) }
    @objc func agentScreen_orderFrontRegardless() { agentScreenHide(); agentScreen_orderFrontRegardless() }
    @objc func agentScreen_makeKeyAndOrderFront(_ sender: Any?) { agentScreenHide(); agentScreen_makeKeyAndOrderFront(sender) }
}
extension NSApplication {
    @objc func agentScreen_activate(ignoringOtherApps flag: Bool) {}
    @objc func agentScreen_activateNow() {}
}

extension NSWorkspace {
    /// Finder and document windows belong to other processes, so our window guard cannot hide them.
    @discardableResult func openOutsideChecks(_ url: URL) -> Bool {
        guard !AgentScreen.active else { return false }
        return open(url)
    }
    func revealOutsideChecks(_ urls: [URL]) {
        guard !AgentScreen.active else { return }
        activateFileViewerSelecting(urls)
    }
}

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
    /// Tells the window's views that the app is visible now, so an error kept back while headless shows.
    var onPromote: @MainActor () -> Void = {}
    private var lastUse = Date()
    /// Commands still running; the copy never quits under one.
    private var inFlight = 0
    /// The main window is off screen because this class put it there, not because someone closed it; a reopen
    /// brings it back rather than letting SwiftUI open a second one.
    var windowHidden = false
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
    /// A control request started or finished: the idle clock starts again.
    func begin() { inFlight += 1; lastUse = Date() }
    func end() { inFlight -= 1; lastUse = Date() }
    /// Become the ordinary app: Dock tile, menu bar, update checks. The main window comes back too, unless another
    /// window is already on screen, so the app is never visible with nothing to show.
    func promote() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        // An --agent-screen copy goes through every step of becoming the ordinary app except gaining a Dock tile.
        NSApp.setActivationPolicy(AgentScreen.active ? .accessory : .regular)
        Updates.shared.resume()
        onPromote()
        guard let window = mainWindow else { return }
        if !AgentScreen.active { window.alphaValue = 1; window.ignoresMouseEvents = false }
        if !NSApp.windows.contains(where: \.isVisible) { window.makeKeyAndOrderFront(nil); windowHidden = false }
    }
    /// Promote and bring the main window forward: --show, or a reopen from the Dock, Spotlight or Finder.
    func reveal() {
        promote()
        mainWindow?.makeKeyAndOrderFront(nil)
        windowHidden = false
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
    private func quitIfIdle() {
        // The hidden main window counts as nothing on screen, even if SwiftUI ordered it back in at alpha 0.
        let shown = NSApp.windows.contains { $0.isVisible && !($0 === mainWindow && windowHidden) }
        guard active, inFlight == 0, !shown, Date().timeIntervalSince(lastUse) >= idleLimit, canQuit() else { return }
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
                Headless.shared.windowHidden = true
                // SwiftUI orders the window front later in the same launch pass; take it away again after that.
                DispatchQueue.main.async { if Headless.shared.active { window.orderOut(nil) } }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}
}
