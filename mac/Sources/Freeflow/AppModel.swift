import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Observable bridge between the SwiftUI dashboard and the app's guts
/// (Dictation, HotKey, Settings, LoginItem). The view binds to these; the
/// setters write through to the real subsystems so changes take effect live.
final class AppModel: ObservableObject {
    /// The flow animator — owned here so the window controller can pause it when
    /// the window isn't being looked at (it's ~0 CPU when stopped).
    let flowClock = FlowClock()

    @Published var recording = false
    /// Raw mic loudness 0…1 (fast). Feeds the flow's slow envelope.
    @Published var level: Double = 0 {
        didSet { glowLevel += (level - glowLevel) * 0.28 }   // smoothed for the light
    }
    /// Smoothed loudness for the glow — no jumpy jitter.
    @Published var glowLevel: Double = 0
    /// Transient note shown in-window (e.g. "copied to clipboard").
    @Published var captureNote = ""
    /// The current utterance's transcript, shown in the floating HUD.
    @Published var transcript = ""
    @Published var shortcutLabel = Settings.shared.shortcutLabel
    @Published var mode = Settings.shared.mode
    @Published var silenceMs = Double(Settings.shared.silenceMs)
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var recordingShortcut = false
    @Published var accessibilityOK = Permissions.accessibilityTrusted(prompt: false)

    // Wired by AppDelegate.
    var onToggleDictation: () -> Void = {}
    var onRebindHotkey: () -> Void = {}
    var onGrantAccessibility: () -> Void = {}

    private var keyMonitor: Any?

    func toggleDictation() { onToggleDictation() }
    func grantAccessibility() { onGrantAccessibility() }

    private var noteClear: DispatchWorkItem?
    func showCaptureNote(_ s: String) {
        captureNote = s
        noteClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation { self?.captureNote = "" }
        }
        noteClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func setMode(_ m: String) { mode = m; Settings.shared.mode = m }
    func setSilence(_ v: Double) { silenceMs = v; Settings.shared.silenceMs = Int(v) }
    func setLaunch(_ on: Bool) { launchAtLogin = on; LoginItem.set(on) }

    func beginRecordShortcut() {
        guard !recordingShortcut else { return }
        recordingShortcut = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            var mods: UInt32 = 0
            if e.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if e.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
            if e.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if e.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
            Settings.shared.keyCode = UInt32(e.keyCode)
            Settings.shared.modifiers = mods
            let label = Self.label(for: e, mods: mods)
            Settings.shared.shortcutLabel = label
            self.shortcutLabel = label
            self.recordingShortcut = false
            if let m = self.keyMonitor { NSEvent.removeMonitor(m); self.keyMonitor = nil }
            self.onRebindHotkey()
            return nil   // consume
        }
    }

    static func label(for e: NSEvent, mods: UInt32) -> String {
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
}
