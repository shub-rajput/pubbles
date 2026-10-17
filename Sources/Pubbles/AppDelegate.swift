import AppKit
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let viewModel = SubtitleViewModel()
    private var overlayController: OverlayController!
    private var eventManager: EventManager!
    private var cursorTracker: CursorTracker!
    private var wiggleDetector: WiggleDetector!
    private var wiggleConfigCancellable: AnyCancellable?
    private var settingsWindowController: SettingsWindowController!
    private var speechManager: SpeechManager!
    private var dictationCancellable: AnyCancellable?
    private var agentControl: AgentControl!
    private var takeController: TakeController!
    private var mcpServer: MCPServer!
    private var agentsConfigCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayController(viewModel: viewModel)
        eventManager = EventManager(viewModel: viewModel)
        cursorTracker = CursorTracker(viewModel: viewModel)
        agentControl = AgentControl(viewModel: viewModel)
        takeController = TakeController(viewModel: viewModel)
        takeController.onChange = { [weak self] in self?.updateTakeStatus() }
        agentControl.onTake = { [weak self] id, version, record in
            self?.takeController.start(id: id, version: version, kind: record ? .recording : .rehearsal)
        }
        agentControl.onStopTake = { [weak self] in self?.takeController.stop() }
        mcpServer = MCPServer(tools: AgentTools(takes: takeController))
        // The MCP server only listens while agent access is on.
        agentsConfigCancellable = ConfigManager.shared.$config
            .map { $0.agents.enabled }
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.mcpServer.start() } else { self?.mcpServer.stop() }
            }
        agentControl.takeStatus = { [weak self] in
            guard let take = self?.takeController else { return [:] }
            var status: [String: Any] = ["running": take.isRunning]
            if let scene = take.sceneLabel { status["scene"] = scene }
            if let last = take.lastResult { status["last"] = last }
            return status
        }

        wiggleDetector = WiggleDetector(viewModel: viewModel)
        wiggleDetector.onWiggle = { [weak self] in
            self?.handleWiggle()
        }

        // Drives initial value AND live updates — @Published emits current value on subscribe
        wiggleConfigCancellable = ConfigManager.shared.$config
            .map { $0.behavior.wiggleSensitivity }
            .removeDuplicates()
            .sink { [weak self] raw in
                self?.wiggleDetector.sensitivity = WiggleDetector.Sensitivity(rawValue: raw) ?? .medium
            }

        speechManager = SpeechManager()

        speechManager.onResult = { [weak self] text, isFinal in
            self?.viewModel.handleDictationResult(fullText: text, isFinal: isFinal)
        }
        speechManager.onError = { error in
            print("SpeechManager error: \(error)")
        }
        speechManager.onLevel = { [weak self] level in
            self?.viewModel.audioLevel = level
        }

        dictationCancellable = viewModel.$dictationModeEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    if !SpeechManager.currentPermissionsGranted() {
                        Task { @MainActor in
                            let granted = await SpeechManager.requestPermissions()
                            guard self.viewModel.dictationModeEnabled else { return }
                            if granted {
                                if !self.viewModel.isActive { self.viewModel.activate() }
                                self.speechManager.startListening()
                            } else {
                                self.viewModel.dictationModeEnabled = false
                                self.viewModel.showTemporaryPill(text: "Enable \(SpeechManager.deniedPermissionLabel()) Permission", timeout: 4)
                            }
                        }
                    } else {
                        self.speechManager.startListening()
                    }
                } else {
                    self.speechManager.stopListening()
                }
            }

        setupMenubar()
        settingsWindowController = SettingsWindowController()
        settingsWindowController.showWindow()
        overlayController.show()
        eventManager.onPermissionMissing = { [weak self] in
            self?.settingsWindowController.showWindow()
        }
        eventManager.onTakeEscape = { [weak self] in
            self?.takeController.stop()
        }
        eventManager.start()
        cursorTracker.start()
        wiggleDetector.start()

        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.viewModel.showOnboarding()
            }
        }

        UpdateChecker.shared.checkForUpdates()
    }

    private func setupMenubar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let iconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Cursor Subtitles")
            }
        }

        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        themeItem.submenu = buildThemeMenu()
        menu.addItem(themeItem)

        let scriptsItem = NSMenuItem(title: "Scripts", action: nil, keyEquivalent: "")
        scriptsItem.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
        scriptsItem.submenu = buildScriptsMenu()
        menu.addItem(scriptsItem)

        menu.addItem(NSMenuItem.separator())

        let configureItem = NSMenuItem(title: "Configure", action: #selector(openSettings), keyEquivalent: "")
        configureItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(configureItem)
        
        let hotkeysItem = NSMenuItem(title: "Hotkeys", action: #selector(openHotkeys), keyEquivalent: "")
        hotkeysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(hotkeysItem)

        let aboutItem = NSMenuItem(title: "About", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    private func buildThemeMenu() -> NSMenu {
        let submenu = NSMenu()
        let currentTheme = ConfigManager.shared.config.theme

        let defaultItem = NSMenuItem(title: "Default", action: #selector(selectDefaultTheme), keyEquivalent: "")
        defaultItem.state = currentTheme == nil ? .on : .off
        submenu.addItem(defaultItem)
        submenu.addItem(NSMenuItem.separator())

        let themes = ConfigManager.shared.availableThemes().filter { $0.filename != "default" }
        for theme in themes {
            let item = NSMenuItem(title: theme.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.filename
            item.state = currentTheme == theme.filename ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(NSMenuItem(title: "Open Themes Folder", action: #selector(openThemesFolder), keyEquivalent: ""))

        return submenu
    }

    @objc private func selectDefaultTheme() {
        ConfigManager.shared.setTheme(nil)
        statusItem.menu = buildMenu()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        let themeName = sender.representedObject as? String
        ConfigManager.shared.setTheme(themeName)
        statusItem.menu = buildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let themeItem = menu.items.first(where: { $0.title == "Theme" }) {
            themeItem.submenu = buildThemeMenu()
        }
        if let scriptsItem = menu.items.first(where: { $0.title == "Scripts" }) {
            scriptsItem.submenu = buildScriptsMenu()
        }
    }

    // MARK: Scripts (temporary home until the Agents tab exists)

    private func buildScriptsMenu() -> NSMenu {
        let submenu = NSMenu()
        if takeController.isRunning {
            let label = takeController.kind == .recording ? "Recording" : "Rehearsing"
            submenu.addItem(NSMenuItem(title: "\(label) · \(takeController.sceneLabel ?? "")", action: nil, keyEquivalent: ""))
            submenu.addItem(NSMenuItem(title: "Stop Take (esc)", action: #selector(stopTake), keyEquivalent: ""))
            return submenu
        }
        let scripts = ScriptStore.list()
        if scripts.isEmpty {
            submenu.addItem(NSMenuItem(title: "No scripts yet", action: nil, keyEquivalent: ""))
        }
        for script in scripts {
            let item = NSMenuItem(title: "\(script.name) (v\(script.latest))", action: nil, keyEquivalent: "")
            let actions = NSMenu()
            for (title, kind) in [("Rehearse", "rehearse"), ("Record", "record")] {
                let action = NSMenuItem(title: title, action: #selector(runTake(_:)), keyEquivalent: "")
                action.representedObject = [script.id, String(script.latest), kind]
                actions.addItem(action)
            }
            item.submenu = actions
            submenu.addItem(item)
        }
        if let last = takeController.lastResult {
            submenu.addItem(NSMenuItem.separator())
            let item = NSMenuItem(title: "Last take: \(last)", action: nil, keyEquivalent: "")
            item.toolTip = last
            submenu.addItem(item)
        }
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Open Scripts Folder", action: #selector(openScriptsFolder), keyEquivalent: ""))

        submenu.addItem(NSMenuItem.separator())
        let agents = ConfigManager.shared.config.agents
        let toggles: [(String, String, Bool)] = [
            ("Let Agents Control Pubbles", "enabled", agents.enabled),
            ("Agents Can Rehearse", "allowRehearse", agents.allowRehearse),
            ("Agents Can Record", "allowRecord", agents.allowRecord),
        ]
        for (i, (title, key, on)) in toggles.enumerated() {
            let item = NSMenuItem(title: title, action: (i == 0 || agents.enabled) ? #selector(toggleAgentSetting(_:)) : nil, keyEquivalent: "")
            item.representedObject = key
            item.state = on ? .on : .off
            if i > 0 { item.indentationLevel = 1 }
            submenu.addItem(item)
        }
        if agents.enabled {
            let status = mcpServer.problem ?? (mcpServer.isListening ? "Listening on \(MCPServer.endpoint)" : "Starting…")
            let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            statusItem.indentationLevel = 1
            submenu.addItem(statusItem)
            submenu.addItem(NSMenuItem(title: "Add to Claude Code", action: #selector(addToClaudeCode), keyEquivalent: ""))
            submenu.addItem(NSMenuItem(title: "Copy Setup Command", action: #selector(copySetupCommand), keyEquivalent: ""))
        }
        return submenu
    }

    @objc private func toggleAgentSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        ConfigManager.shared.setAgentsValue(key, sender.state != .on)
    }

    @objc private func copySetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPServer.claudeAddCommand, forType: .string)
    }

    /// Runs `claude mcp add` through a login shell (so the user's PATH finds `claude`), replacing any
    /// earlier Pubbles entry.
    @objc private func addToClaudeCode() {
        let script = "claude mcp remove --scope user pubbles >/dev/null 2>&1; \(MCPServer.claudeAddCommand)"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var text: String
            var ok = false
            do {
                try process.run()
                process.waitUntilExit()
                text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                ok = process.terminationStatus == 0
            } catch {
                text = error.localizedDescription
            }
            let message = ok
                ? "Pubbles is added to Claude Code. Start a new Claude Code session to use it."
                : "Couldn't add Pubbles to Claude Code:\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\nYou can paste the setup command yourself (Copy Setup Command)."
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = ok ? "Added to Claude Code" : "Not added"
                alert.informativeText = message
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func runTake(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 3, let version = Int(info[1]) else { return }
        takeController.start(id: info[0], version: version, kind: info[2] == "record" ? .recording : .rehearsal)
    }

    @objc private func stopTake() {
        takeController.stop()
    }

    /// Menubar shows REC / ▶ while a take runs.
    private func updateTakeStatus() {
        guard let button = statusItem.button else { return }
        if takeController.isRunning {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.title = takeController.kind == .recording ? " REC" : " Rehearsing"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    @objc private func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: TakeController.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(TakeController.recordingsFolder)
    }

    @objc private func openScriptsFolder() {
        try? FileManager.default.createDirectory(at: ScriptStore.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ScriptStore.folder)
    }

    @objc private func openThemesFolder() {
        let themesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pubbles/themes")
        NSWorkspace.shared.open(themesURL)
    }

    @objc private func openSettings() {
        settingsWindowController.showWindow()
    }

    @objc private func openHotkeys() {
        settingsWindowController.showWindow(tab: .hotkeys)
    }

    @objc private func openAbout() {
        settingsWindowController.showWindow(tab: .about)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController.showWindow()
        return true
    }

    private func handleWiggle() {
        let behavior = ConfigManager.shared.config.behavior
        guard behavior.wiggleEnabled, !viewModel.takeInProgress else { return }
        switch behavior.wiggleToActivate {
        case "pubble":
            viewModel.drawingModeEnabled = false
            if !viewModel.isActive { viewModel.activate() }
        case "babble":
            viewModel.drawingModeEnabled = false
            if !viewModel.dictationModeEnabled { viewModel.toggleDictation() }
        case "doodle":
            if !viewModel.drawingToggleActive { viewModel.toggleDrawing() }
        default:
            break
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
