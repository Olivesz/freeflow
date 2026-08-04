import AppKit
import Carbon.HIToolbox

/// A small, functional settings window (built in code — no xib). Lets the user
/// rebind the trigger, pick tap-vs-hold, tune the auto-stop delay, and toggle
/// launch-at-login. Calls `onShortcutChange` so the app re-registers the hotkey.
final class SettingsWindowController: NSWindowController {
    var onShortcutChange: (() -> Void)?

    private let recordButton = NSButton()
    private let silenceLabel = NSTextField(labelWithString: "")
    private var keyMonitor: Any?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "freeflow Settings"
        self.init(window: window)
        buildUI()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI
    private func buildUI() {
        let s = Settings.shared

        recordButton.title = s.shortcutLabel
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(recordShortcut)

        let mode = NSSegmentedControl(labels: ["Tap to toggle", "Hold to talk"],
                                      trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        mode.selectedSegment = s.mode == "hold" ? 1 : 0

        let slider = NSSlider(value: Double(s.silenceMs), minValue: 600, maxValue: 3000,
                              target: self, action: #selector(silenceChanged))
        silenceLabel.stringValue = "\(s.silenceMs) ms"

        let login = NSButton(checkboxWithTitle: "Launch freeflow at login",
                             target: self, action: #selector(loginChanged))
        login.state = LoginItem.isEnabled ? .on : .off

        let rows = NSStackView(views: [
            row("Shortcut", recordButton),
            row("Trigger", mode),
            row("Auto-stop after", stack([slider, silenceLabel])),
            row("", login),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 16
        rows.translatesAutoresizingMaskIntoConstraints = false

        let content = window!.contentView!
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return stack([label, control])
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 10
        return s
    }

    // MARK: - Actions
    @objc private func recordShortcut() {
        recordButton.title = "Press keys…"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            var mods: UInt32 = 0
            if e.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if e.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
            if e.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if e.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }

            Settings.shared.keyCode = UInt32(e.keyCode)
            Settings.shared.modifiers = mods
            let label = self.label(for: e, mods: mods)
            Settings.shared.shortcutLabel = label
            self.recordButton.title = label

            if let m = self.keyMonitor { NSEvent.removeMonitor(m); self.keyMonitor = nil }
            self.onShortcutChange?()
            return nil   // consume the keypress
        }
    }

    private func label(for e: NSEvent, mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        switch Int(e.keyCode) {
        case kVK_Space:  s += "Space"
        case kVK_Return: s += "Return"
        case kVK_Tab:    s += "Tab"
        case kVK_Escape: s += "Esc"
        default:
            let ch = (e.charactersIgnoringModifiers ?? "").uppercased()
            s += ch.isEmpty ? "Key\(e.keyCode)" : ch
        }
        return s
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        Settings.shared.mode = sender.selectedSegment == 1 ? "hold" : "toggle"
    }

    @objc private func silenceChanged(_ sender: NSSlider) {
        Settings.shared.silenceMs = Int(sender.doubleValue)
        silenceLabel.stringValue = "\(Int(sender.doubleValue)) ms"
    }

    @objc private func loginChanged(_ sender: NSButton) {
        LoginItem.set(sender.state == .on)
    }
}
