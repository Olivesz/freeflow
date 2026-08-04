import Carbon.HIToolbox
import Foundation

/// Persisted user settings (UserDefaults). The whole config surface: which key
/// triggers dictation, tap-vs-hold, and how long a silence ends an utterance.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var keyCode: UInt32 {
        get { UInt32(d.object(forKey: "keyCode") as? Int ?? kVK_Space) }
        set { d.set(Int(newValue), forKey: "keyCode") }
    }
    var modifiers: UInt32 {
        get { UInt32(d.object(forKey: "modifiers") as? Int ?? optionKey) }
        set { d.set(Int(newValue), forKey: "modifiers") }
    }
    var shortcutLabel: String {
        get { d.string(forKey: "shortcutLabel") ?? "⌥Space" }
        set { d.set(newValue, forKey: "shortcutLabel") }
    }
    /// "toggle" = tap to start / tap or silence to stop. "hold" = push-to-talk.
    var mode: String {
        get { d.string(forKey: "mode") ?? "toggle" }
        set { d.set(newValue, forKey: "mode") }
    }
    var silenceMs: Int {
        get { d.object(forKey: "silenceMs") as? Int ?? 1500 }
        set { d.set(newValue, forKey: "silenceMs") }
    }
}
