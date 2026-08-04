# freeflow — Cross-Platform Architecture

Turning freeflow from a terminal script into an installable product on **macOS**
and **iPhone**, keeping it minimal and (mostly) free.

## Guiding constraint: what surface may insert text?

The OSes differ in what a third-party app is allowed to do. This single table
drives every decision below.

| Capability | macOS | iOS |
|---|---|---|
| Register a global hotkey | ✅ | ❌ |
| Access mic from background/on-demand | ✅ | ❌ (foreground / entitled surfaces only) |
| Insert text into **any other app** | ✅ (Accessibility / CGEvent) | ❌ — **only** via a custom keyboard extension |
| On-device speech model of our choosing | ✅ whisper.cpp | ⚠️ memory-capped; use Apple Speech instead |

**Consequence:** on macOS we keep the engine we built. On iOS, "type anywhere"
is deliverable *only* through a **custom keyboard**, and the trigger must live on
that keyboard (there is no way to type into another app from a background gesture).

---

## macOS — native Swift menubar app

```
┌─ freeflow.app (menubar, no dock icon) ─────────────────────────┐
│  Launch at login .......... SMAppService (modern login item)    │
│  Global hotkey ............ toggle / hold, rebindable in-UI      │
│  Settings window .......... ⌨ hotkey recorder · model · mode ·   │
│                             launch-at-login · silence delay      │
│  Engine ................... whisper.cpp + CoreML (Neural Engine) │
│  Mic ...................... AVAudioEngine @ 16 kHz               │
│  Insert ................... CGEvent keystrokes / Accessibility   │
└─────────────────────────────────────────────────────────────────┘
```

- **Reuses our validated logic** — streaming stabilization (LocalAgreement),
  VAD endpointing, and the hallucination guard — ported from Python to the
  shared Swift core (below). The *algorithms* are done; this is re-expression.
- **Permissions**: Microphone, Accessibility, Input Monitoring — same three as
  today, but a proper signed bundle means the grant is stable (no TCC ambiguity
  like the nested-under-Claude problem).
- **Hotkey UI**: a "click to record a shortcut" field (the standard macOS
  pattern). Functional and clean, nothing grand.

## iOS — container app + custom keyboard extension

```
┌─ freeflow (container app) ──────────┐   ┌─ freeflowKeyboard (extension) ─────┐
│  • Onboarding & permissions          │   │  Appears in EVERY text field       │
│  • Requests: Mic, Speech recognition │   │  Trigger: triple-tap space / mic ⌨ │
│  • Enable keyboard + Full Access     │   │  Engine: SFSpeechRecognizer         │
│  • Settings (gesture, on-device)     │   │          (on-device, free, ANE)     │
└──────────────────────────────────────┘   │  Insert: textDocumentProxy → field  │
                                            │          (DIRECT, no paste)         │
                                            └─────────────────────────────────────┘
```

- **Engine = Apple's on-device Speech framework**, NOT Whisper. Keyboard
  extensions run under a tight memory ceiling; Whisper won't fit reliably, and
  `SFSpeechRecognizer(requiresOnDeviceRecognition: true)` is free, private, and
  Neural-Engine accelerated. On iOS the value is the seamless keyboard UX, not
  the model.
- **Trigger** lives on the keyboard: triple-tap the space bar, or a mic key.
  (Phone-back Back-Tap can't insert text into another app, so it's out for the
  no-paste requirement.)
- **Direct insert** via `textDocumentProxy.insertText()` — exactly the "straight
  into the field" behavior wanted, no clipboard step.

### ⚠️ Risk to de-risk FIRST (1-day spike)
Whether a keyboard extension can access the **microphone** and run
**SFSpeechRecognizer** at all (requires "Allow Full Access"; Apple is historically
restrictive here). **Build a throwaway keyboard that records 2s and inserts the
transcript before committing to anything else.** The entire iOS plan rests on this.

### iOS cost tiers
- **Your own phone**: free Apple ID + Xcode free provisioning (re-sign weekly). $0.
- **Share with others**: Apple Developer Program, $99/yr, App Store review.
- Note: App Groups (shared settings between app & keyboard) need the paid
  account; a personal v1 keeps settings self-contained in the extension.

---

## Shared core (Swift package: `FreeflowCore`)

Pure, UI-free, testable logic shared by both platforms:

- `HypothesisBuffer` — LocalAgreement word stabilization (append-only).
- `EndpointDetector` — VAD / silence endpointing.
- Non-speech / hallucination filtering.
- Config model.

macOS binds this to whisper.cpp; iOS binds it to Apple Speech (which does its own
endpointing, so iOS uses less of the core). The Python implementation remains the
reference/prototype and the source of the ported logic + tests.

---

## Roadmap

1. **Mac off the terminal** — native Swift menubar app: login item, rebindable
   hotkey, settings, whisper.cpp engine, our ported logic. *(first buildable)*
2. **iOS spike** — throwaway keyboard proving mic + on-device Speech + insert.
3. **iOS v1** — real keyboard extension + container app, on your own device (free).
4. **Go-public (optional)** — Apple Developer account, notarized Mac app +
   App Store iOS app, App Groups for shared settings.

## Open decisions
- Reach (private vs public) — deferred; nothing here locks it out.
- Whether to keep the Python prototype maintained alongside, or freeze it once
  the Swift core lands.
