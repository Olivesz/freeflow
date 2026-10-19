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
    /// True while dictating without Accessibility — keystrokes can't land, so the
    /// HUD stays up as a warning + recovery surface instead of failing silently.
    @Published var injectionBlocked = false
    /// True while the HUD shows a transient status (e.g. "warming up…"), so it
    /// doesn't offer a Copy button for a non-transcript message.
    @Published var statusFlash = false

    // MARK: Voice-feature toggles (write through to Settings; Dictation reads them at start)
    @Published var fillerCleanup = Settings.shared.fillerCleanup {
        didSet { Settings.shared.fillerCleanup = fillerCleanup }
    }
    @Published var voiceCommands = Settings.shared.voiceCommands {
        didSet { Settings.shared.voiceCommands = voiceCommands }
    }
    @Published var spokenPunctuation = Settings.shared.spokenPunctuation {
        didSet { Settings.shared.spokenPunctuation = spokenPunctuation }
    }
    @Published var autoCapitalize = Settings.shared.autoCapitalize {
        didSet { Settings.shared.autoCapitalize = autoCapitalize }
    }

    // MARK: Custom vocabulary
    @Published var vocab: [String: String] = Settings.shared.vocab
    /// Sorted for stable display in the editor.
    var vocabPairs: [(spoken: String, replacement: String)] {
        vocab.sorted { $0.key < $1.key }.map { (spoken: $0.key, replacement: $0.value) }
    }
    func addVocab(_ spoken: String, _ replacement: String) {
        let key = spoken.trimmingCharacters(in: .whitespaces).lowercased()
        let val = replacement.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !val.isEmpty else { return }
        vocab[key] = val
        Settings.shared.vocab = vocab
    }
    func removeVocab(_ key: String) {
        vocab[key] = nil
        Settings.shared.vocab = vocab
    }

    // MARK: History
    /// Recent dictations, newest first (mirrors HistoryStore for the UI).
    @Published var history: [Dictation_Entry] = HistoryStore.shared.entries

    /// Record a finished dictation into history (persisted + published), and
    /// keep its audio when the user opted in.
    func recordHistory(_ text: String, audio: [Float]) {
        guard let entry = HistoryStore.shared.add(text) else { return }
        history = HistoryStore.shared.entries
        if keepRecordings {
            RecordingStore.shared.save(id: entry.id, audio: audio, typed: entry.text, model: ModelLocator.name)
            recordingCount += 1
        }
    }

    /// The user's fix for a dictation: what they actually said. Becomes the
    /// reference for that recording.
    func correct(_ id: UUID, to text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        HistoryStore.shared.setCorrected(id: id, text: t)
        RecordingStore.shared.setCorrected(id: id, text: t)
        history = HistoryStore.shared.entries
    }

    // MARK: Recordings (opt-in tuning data)
    @Published var keepRecordings = Settings.shared.keepRecordings {
        didSet { Settings.shared.keepRecordings = keepRecordings }
    }
    @Published var recordingCount = RecordingStore.shared.count
    func deleteRecordings() {
        RecordingStore.shared.deleteAll()
        recordingCount = 0
    }
    func clearHistory() {
        HistoryStore.shared.clear()
        history = []
    }
    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showCaptureNote("copied")
    }

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
