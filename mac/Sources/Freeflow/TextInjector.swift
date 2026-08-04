import AppKit
import CoreGraphics

/// Types text into whatever app currently has focus, by posting synthetic
/// keyboard events. Requires Accessibility permission. Supports full Unicode
/// (emoji, CJK) via `keyboardSetUnicodeString`, and backspacing so we can
/// revise streamed text in place when the recognizer changes its mind.
enum TextInjector {
    private static let source = CGEventSource(stateID: .combinedSessionState)

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let utf16 = Array(text.utf16)
        var i = 0
        let chunk = 20   // one event carries a bounded unicode string
        while i < utf16.count {
            let slice = Array(utf16[i..<min(i + chunk, utf16.count)])
            post(unicode: slice, down: true)
            post(unicode: slice, down: false)
            i += chunk
        }
    }

    static func deleteBackward(_ count: Int) {
        guard count > 0 else { return }
        let delete: CGKeyCode = 0x33   // kVK_Delete
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private static func post(unicode: [UniChar], down: Bool) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
        e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        e.post(tap: .cghidEventTap)
    }
}
