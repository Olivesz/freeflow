import AppKit
import SwiftUI

/// Hosts the SwiftUI dashboard in a borderless-feeling window. Also gates the
/// flow animation on focus: it only runs while you're actually looking at the
/// window (key), and stops when it's backgrounded or closed — so the pretty
/// idle window doesn't burn CPU in the background.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let host = NSHostingController(rootView: DashboardView(model: model))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.title = "freeflow"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 600))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Animate only while the window is actually being looked at.
    func windowDidBecomeKey(_ notification: Notification) { model.flowClock.start() }
    func windowDidResignKey(_ notification: Notification) { model.flowClock.stop() }
    func windowWillClose(_ notification: Notification) { model.flowClock.stop() }
    func windowDidMiniaturize(_ notification: Notification) { model.flowClock.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { model.flowClock.start() }
}
