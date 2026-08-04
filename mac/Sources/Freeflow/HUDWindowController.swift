import AppKit
import SwiftUI

/// Hosts the dictation pill in a NON-ACTIVATING floating panel: it can appear,
/// update, and even be clicked (the Copy button) without ever making freeflow
/// the focused app — so your text field keeps focus and dictation still lands.
/// This is the whole point: a visible surface that isn't a focus thief.
final class HUDWindowController: NSWindowController {
    convenience init(model: AppModel, onCopy: @escaping () -> Void) {
        let host = NSHostingView(rootView: HUDView(model: model, onCopy: onCopy))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.init(window: panel)
    }

    func show() {
        reposition()
        window?.orderFrontRegardless()   // appear without activating freeflow
    }

    func hide() { window?.orderOut(nil) }

    private func reposition() {
        guard let window, let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 120))
    }
}
