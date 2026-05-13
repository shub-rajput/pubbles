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

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayController(viewModel: viewModel)
        eventManager = EventManager(viewModel: viewModel)
        cursorTracker = CursorTracker(viewModel: viewModel)

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

        menu.addItem(NSMenuItem.separator())

        let hotkeysItem = NSMenuItem(title: "Hotkeys", action: #selector(openHotkeys), keyEquivalent: "")
        hotkeysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(hotkeysItem)

        let configureItem = NSMenuItem(title: "Configure", action: #selector(openSettings), keyEquivalent: "")
        configureItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(configureItem)

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
        guard behavior.wiggleEnabled else { return }
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
