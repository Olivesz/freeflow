import AppKit
import ApplicationServices
import FreeflowCore

/// Reads back, a while after a dictation, what the user did to the text it
/// typed, through Accessibility: the field's value right after typing, then
/// again `delay` seconds later or when the next dictation starts, whichever
/// comes first. Only the dictated span is kept, never the rest of the field,
/// and secure (password) fields are never read.
///
/// Apps that don't expose their text to Accessibility are logged as `no_ax`,
/// so their share of dictations is known rather than silently missing.
final class CorrectionWatcher {
    static let delay: TimeInterval = 90

    private struct Pending {
        let id: UUID, app: String?, element: AXUIElement
        let before: String, span: Range<Int>, typed: String, at: Date
        let work: DispatchWorkItem
    }
    private var pending: Pending?
    private var generation = 0                 // bumped when a dictation starts
    private let log: SessionLog

    init(log: SessionLog) { self.log = log }

    /// Right after a dictation finished typing. Main thread. The last
    /// keystrokes reach the app asynchronously, so the first read retries.
    func watch(_ trace: SessionTrace) {
        resolve()                                       // a previous one still waiting: read it now
        guard !trace.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        attempt(trace, waits: [0.3, 0.8, 1.5])
    }

    /// A new dictation is starting: settle the last one before it types more.
    func dictationStarted() {
        generation += 1
        resolve()
    }

    private func attempt(_ trace: SessionTrace, waits: [Double]) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (waits.first ?? 0)) { [weak self] in
            guard let self, self.generation == gen else { return }   // superseded: field now has newer text
            self.capture(trace, retries: Array(waits.dropFirst()))
        }
    }

    private func capture(_ trace: SessionTrace, retries: [Double]) {
        let typed = trace.typed
        guard let el = Self.focusedElement(), !Self.isSecure(el), let value = Self.value(el) else {
            log.recordEdit(id: trace.id, status: "no_ax", app: trace.app, delay: 0, typed: nil, followed: nil)
            return
        }
        guard let span = CorrectionTrail.locate(typed, in: value, caret: Self.caret(el)) else {
            if retries.isEmpty {
                log.recordEdit(id: trace.id, status: "not_found", app: trace.app, delay: 0, typed: nil, followed: nil)
            } else {
                attempt(trace, waits: retries)
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.resolve() }
        pending = Pending(id: trace.id, app: trace.app, element: el, before: value, span: span,
                          typed: typed, at: Date(), work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Reads the field back now. Called by the timer and when a dictation starts.
    func resolve() {
        guard let p = pending else { return }
        pending = nil
        p.work.cancel()
        let delay = Date().timeIntervalSince(p.at)
        guard let now = Self.value(p.element) else {
            log.recordEdit(id: p.id, status: "gone", app: p.app, delay: delay, typed: p.typed, followed: nil)
            return
        }
        let f = CorrectionTrail.follow(span: p.span, before: p.before, after: now)
        log.recordEdit(id: p.id, status: f == nil ? "lost" : "ok", app: p.app, delay: delay,
                       typed: p.typed, followed: f)
    }

    // MARK: Accessibility

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func focusedElement() -> AXUIElement? {
        guard let v = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        (attr(el, kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String)
    }

    static func value(_ el: AXUIElement) -> String? { attr(el, kAXValueAttribute) as? String }

    static func caret(_ el: AXUIElement) -> Int? {
        guard let v = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r.location + r.length : nil
    }
}
