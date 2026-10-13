import AppKit
import AVFoundation
import SwiftUI

/// Hosts the first-run walkthrough and polls the live permission state (mic +
/// Accessibility) every 0.4s so the checkmarks flip the instant the user grants
/// access in System Settings — no relaunch, no guessing.
final class OnboardingWindowController: NSWindowController {
    private let obModel = OnboardingModel()
    private var poll: Timer?
    private let onDone: () -> Void

    init(onOpenAccessibility: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.onDone = onDone
        let host = NSHostingController(rootView: OnboardingView(model: obModel))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 560))
        window.center()
        super.init(window: window)

        obModel.onRequestMic = {
            // First time: show the system prompt. If already denied, the system
            // won't re-prompt — send them to the Settings pane instead.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Permissions.requestMic { _ in }
            } else if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
        obModel.onOpenAccessibility = onOpenAccessibility
        obModel.onFinish = { [weak self] in self?.finish() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show() {
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        obModel.micOK = mic == .authorized
        obModel.micDenied = mic == .denied || mic == .restricted
        obModel.axOK = Permissions.accessibilityTrusted(prompt: false)
    }

    private func finish() {
        Settings.shared.hasOnboarded = true
        poll?.invalidate(); poll = nil
        window?.close()
        onDone()
    }
}
