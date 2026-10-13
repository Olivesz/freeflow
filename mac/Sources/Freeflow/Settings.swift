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

    // MARK: - Text processing (vocab / filler / commands)
    private func flag(_ key: String, default def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }

    var fillerCleanup: Bool {
        get { flag("fillerCleanup", default: true) }
        set { d.set(newValue, forKey: "fillerCleanup") }
    }
    var voiceCommands: Bool {
        get { flag("voiceCommands", default: true) }
        set { d.set(newValue, forKey: "voiceCommands") }
    }
    var spokenPunctuation: Bool {
        get { flag("spokenPunctuation", default: false) }
        set { d.set(newValue, forKey: "spokenPunctuation") }
    }
    var autoCapitalize: Bool {
        get { flag("autoCapitalize", default: true) }
        set { d.set(newValue, forKey: "autoCapitalize") }
    }

    /// User's correction dictionary: spoken word (lowercased) → replacement.
    var vocab: [String: String] {
        get {
            guard let data = d.data(forKey: "vocabJSON"),
                  let map = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return map
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "vocabJSON") }
    }

    /// False until the first-run onboarding has been completed/dismissed.
    var hasOnboarded: Bool {
        get { flag("hasOnboarded", default: false) }
        set { d.set(newValue, forKey: "hasOnboarded") }
    }

    /// Builds the processor config from the current settings.
    func textProcessorConfig() -> TextProcessor.Config {
        TextProcessor.Config(filler: fillerCleanup, commands: voiceCommands,
                             punctuation: spokenPunctuation, autoCap: autoCapitalize,
                             vocab: vocab)
    }
}
