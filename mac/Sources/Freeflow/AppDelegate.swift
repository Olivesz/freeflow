import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let dictation = Dictation()
    private let hotKey = HotKey()
    private let model = AppModel()
    private var mainWindow: MainWindowController!
    private var hud: HUDWindowController!
    private var hudHide: DispatchWorkItem?
    private var hudShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)

        dictation.onEdit = { [weak self] _, insert in
            TextInjector.insert(insert)        // type straight into the focused field (append-only)
            self?.model.transcript += insert   // mirror into the floating HUD
        }
        dictation.onState = { [weak self] recording in
            guard let self else { return }
            self.setIcon(recording: recording)
            self.model.recording = recording
            if recording {
                self.hudHide?.cancel()
                self.model.transcript = ""
                // Only float the pill when the words have nowhere visible to land.
                self.hudShown = !AXFocus.hasExternalTarget()
                if self.hudShown { self.hud.show() }
            } else if self.hudShown {
                self.scheduleHUDHide()
            }
            self.rebuildMenu()
        }
        dictation.onLevel = { [weak self] lvl in
            DispatchQueue.main.async { self?.model.level = Double(lvl) }
        }

        // Bridge the dashboard's controls to the real subsystems.
        model.onToggleDictation = { [weak self] in self?.dictation.toggle() }
        model.onRebindHotkey = { [weak self] in self?.registerHotKey(); self?.rebuildMenu() }
        model.onGrantAccessibility = { [weak self] in self?.openAccessibility() }

        configureHotKey()

        mainWindow = MainWindowController(model: model)
        hud = HUDWindowController(model: model, onCopy: { [weak self] in self?.copyTranscript() })

        rebuildMenu()
        requestPermissions()
        mainWindow.show()   // greet the user with the window
    }

    // MARK: - Hotkey
    private func configureHotKey() {
        hotKey.onDown = { [weak self] in
            guard let self else { return }
            Settings.shared.mode == "hold" ? self.dictation.start() : self.dictation.toggle()
        }
        hotKey.onUp = { [weak self] in
            guard let self else { return }
            if Settings.shared.mode == "hold" { self.dictation.stop() }
        }
        registerHotKey()
    }

    private func registerHotKey() {
        hotKey.register(keyCode: Settings.shared.keyCode, modifiers: Settings.shared.modifiers)
    }

    // MARK: - Permissions
    private func requestPermissions() {
        Permissions.requestMic { _ in }
        if !Permissions.accessibilityTrusted(prompt: false) {
            Permissions.accessibilityTrusted(prompt: true)
        }
    }

    // MARK: - Menubar
    private func setIcon(recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "freeflow")
    }

    private func rebuildMenu() {
        model.accessibilityOK = Permissions.accessibilityTrusted(prompt: false)
        let menu = NSMenu()
        menu.addItem(withTitle: dictation.isRunning ? "● Listening…" : "freeflow — idle",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Open freeflow", #selector(openMain))
        if !model.accessibilityOK {
            add(menu, "⚠︎ Grant Accessibility…", #selector(openAccessibility))
        }
        menu.addItem(.separator())
        add(menu, "Quit freeflow", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions
    @objc private func openMain() { mainWindow.show() }

    @objc private func openAccessibility() {
        Permissions.accessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - HUD
    private func scheduleHUDHide() {
        hudHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud.hide() }
        hudHide = work
        // Linger a few seconds after you stop so you can read it / hit Copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func copyTranscript() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(model.transcript, forType: .string)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // Clicking the dock icon (with no window open) reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }
}
