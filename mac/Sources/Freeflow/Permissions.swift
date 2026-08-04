import AVFoundation
import ApplicationServices
import Speech

/// The three grants freeflow needs. Microphone and Speech show system prompts;
/// Accessibility can't be prompted programmatically beyond opening the pane, so
/// we detect it and let the UI guide the user there.
enum Permissions {
    static func requestMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { done(ok) }
        }
        default: done(false)
        }
    }

    static func requestSpeech(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    /// True if we may synthesize keystrokes. `prompt: true` pops the system
    /// dialog that offers to open the Accessibility settings pane.
    @discardableResult
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
