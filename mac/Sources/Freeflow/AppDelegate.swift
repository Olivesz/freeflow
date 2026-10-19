import AppKit
import FreeflowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let dictation = Dictation()
    private let watcher = CorrectionWatcher(log: .shared)
    private let hotKey = HotKey()
    private let model = AppModel()
    private var mainWindow: MainWindowController!
    private var onboarding: OnboardingWindowController?
    private var hud: HUDWindowController!
    private var hudHide: DispatchWorkItem?
    private var hudShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)

        dictation.onOps = { [weak self] ops in
            guard let self else { return }
            for op in ops {
                switch op {
                case .insert(let text):
                    TextInjector.insert(text)              // type into the focused field
                    self.model.transcript += text          // mirror into the floating HUD
                case .delete(let n):
                    TextInjector.deleteBackward(n)          // "scratch that" — bounded to this utterance
                    self.model.transcript = String(self.model.transcript.dropLast(n))
                }
            }
        }
        dictation.onFinished = { [weak self] trace in
            guard let self else { return }
            self.model.recordHistory(trace)
            if self.model.keepRecordings { self.watcher.watch(trace) }
        }
        dictation.onEngineLoaded = { [weak self] name in self?.model.activeEngine = name }
        model.activeEngine = dictation.engineName      // in case it loaded before the callback existed
        model.onEngineChange = { [weak self] in
            self?.model.activeEngine = ""
            self?.dictation.reload()
        }
        dictation.onState = { [weak self] recording in
            guard let self else { return }
            self.setIcon(recording: recording)
            self.model.recording = recording
            if recording {
                self.watcher.dictationStarted()
                self.hudHide?.cancel()
                self.model.statusFlash = false
                self.model.transcript = ""
                let canType = Permissions.accessibilityTrusted(prompt: false)
                self.model.injectionBlocked = !canType
                // Float the pill when the words have nowhere visible to land, OR when
                // injection is blocked (so they're never lost — recoverable via Copy).
                // Not during onboarding: the "try it" box is already right there.
                self.hudShown = (!AXFocus.hasExternalTarget() || !canType) && self.onboarding == nil
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

        if Settings.shared.hasOnboarded {
            requestPermissions()
            mainWindow.show()          // greet returning users with the window
        } else {
            showOnboarding()           // first run: guided setup
        }
    }

    private func showOnboarding() {
        let ob = OnboardingWindowController(
            onOpenAccessibility: { [weak self] in self?.openAccessibility() },
            onDone: { [weak self] in
                guard let self else { return }
                self.model.accessibilityOK = Permissions.accessibilityTrusted(prompt: false)
                self.rebuildMenu()
                self.mainWindow.show()
                self.onboarding = nil
            })
        onboarding = ob
        ob.show()
    }

    // MARK: - Hotkey
    private func configureHotKey() {
        hotKey.onDown = { [weak self] in
            guard let self else { return }
            guard self.dictation.isReady else { self.flashHUD("warming up…"); return }
            self.dictation.trigger = Settings.shared.mode
            Settings.shared.mode == "hold" ? self.dictation.start() : self.dictation.toggle()
        }
        hotKey.onUp = { [weak self] in
            guard let self else { return }
            if Settings.shared.mode == "hold" { self.dictation.stop() }
        }
        registerHotKey()
    }

    /// Briefly float the pill with a status message (e.g. the model is still
    /// loading) so a keypress never feels like it did nothing.
    private func flashHUD(_ message: String) {
        hudHide?.cancel()
        model.injectionBlocked = false
        model.recording = false
        model.statusFlash = true
        model.transcript = message
        hud.show(); hudShown = true
        let work = DispatchWorkItem { [weak self] in
            self?.hud.hide(); self?.hudShown = false; self?.model.statusFlash = false
        }
        hudHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
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
        // Discoverability: always show the trigger key right in the menu.
        let hint = NSMenuItem(title: "Press \(Settings.shared.shortcutLabel) to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        add(menu, "Open freeflow", #selector(openMain))
        let copyLast = add(menu, "Copy last dictation", #selector(copyLastDictation))
        copyLast.isEnabled = !model.history.isEmpty
        if !model.accessibilityOK {
            add(menu, "⚠︎ Grant Accessibility…", #selector(openAccessibility))
        }
        add(menu, "Setup guide…", #selector(openSetupGuide))
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

    @objc private func openSetupGuide() { showOnboarding() }

    @objc private func copyLastDictation() {
        guard let last = model.history.first?.text else { return }
        model.copyToClipboard(last)
    }

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
