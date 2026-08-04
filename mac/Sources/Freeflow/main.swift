import AppKit

// Hidden self-test path for verifying the Whisper streaming port headlessly.
if let i = CommandLine.arguments.firstIndex(of: "--selftest"),
   i + 1 < CommandLine.arguments.count {
    SelfTest.run(CommandLine.arguments[i + 1])   // never returns
}

if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
    RenderUI.run(CommandLine.arguments[i + 1])   // never returns
}

// Menubar-only agent app: no dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // real desktop app: dock icon + window (also lives in the menubar)
app.run()
