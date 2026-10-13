import AppKit

/// COSMETIC ONLY — decides whether to float the HUD pill; never gates typing.
///
/// Rule: show the pill only when you're NOT in a text box. The
/// robust signal for that is simply "is another app frontmost?" — if you clicked
/// into a field, that app is frontmost (you're in it), so hide the pill; if
/// freeflow's own window is frontmost (you're just watching it) or nothing is,
/// show it. We deliberately avoid asking apps "what element is focused?" because
/// Electron/Chromium apps (VS Code, Slack) and some browsers don't
/// expose it — which made the pill show *everywhere*.
enum AXFocus {
    static func hasExternalTarget() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier != getpid()   // another app is up → you're in it
    }
}
