@preconcurrency import AppKit
@preconcurrency import CoreGraphics

@MainActor
final class EventManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selfPtr: Unmanaged<EventManager>?
    private var permissionTimer: Timer?
    private let viewModel: SubtitleViewModel

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    var onPermissionMissing: (() -> Void)?
    /// Esc pressed while a scripted take is playing.
    var onTakeEscape: (() -> Void)?

    func start() {
        if !AXIsProcessTrusted() {
            onPermissionMissing?()
            waitForPermission()
            return
        }

        setupEventTap()
    }

    private func waitForPermission() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.setupEventTap()
                }
            }
        }
    }

    private func setupEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let retainedSelf = Unmanaged.passRetained(self)
        self.selfPtr = retainedSelf

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: retainedSelf.toOpaque()
        )

        guard let tap = eventTap else {
            print("Failed to create event tap.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Called from the CGEvent tap callback on an arbitrary thread.
    // We only read viewModel.isActive (which is safe enough for a quick check)
    // and dispatch all mutations to the main actor.
    nonisolated private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled by the system, but only if we still have permission.
        // Always dispatch to main to avoid a tight re-enable loop: AXIsProcessTrusted() can
        // lag a few seconds after permission is revoked, so checking it synchronously here
        // may return true and immediately re-enable a tap the system just disabled, which
        // causes macOS to fire tapDisabledByTimeout again — a busy loop that lags the system.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Guard: if tearDownEventTap() already ran, do nothing.
                    guard self.eventTap != nil else { return }
                    if AXIsProcessTrusted() {
                        if let tap = self.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    } else {
                        self.handlePermissionLost()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // During a scripted take the bubble belongs to the agent: leave the user's input alone,
        // except Esc, which stops the take.
        if MainActor.assumeIsolated({ self.viewModel.takeInProgress }) {
            if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onTakeEscape?() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Track modifier key state for hold-to-draw
        if type == .flagsChanged {
            let (drawingHotkey, drawingMods) = MainActor.assumeIsolated {
                let h = ConfigManager.shared.config.drawingHotkey
                return (h, Self.parseHotkey(h).0)
            }
            let modifierHeld = !drawingHotkey.isEmpty && event.flags.contains(drawingMods.cgEventFlags)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Don't override drawing mode while toggle is active
                    guard !self.viewModel.drawingToggleActive else { return }
                    if self.viewModel.drawingModeEnabled != modifierHeld {
                        self.viewModel.drawingModeEnabled = modifierHeld
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Mouse click — dismiss pill (drawing is handled by overlay window gesture)
        if type == .leftMouseDown || type == .rightMouseDown {
            let (isActive, drawingEnabled, clickToDismiss, pinHotkeyStr, pinMods) = MainActor.assumeIsolated {
                let h = ConfigManager.shared.config.pinHotkey
                return (
                    self.viewModel.isActive,
                    self.viewModel.drawingModeEnabled,
                    ConfigManager.shared.config.behavior.clickToDismiss,
                    h,
                    Self.parseHotkey(h).0
                )
            }

            // When drawing mode is on, overlay window handles left clicks — don't dismiss
            if type == .leftMouseDown && isActive && !drawingEnabled && clickToDismiss {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.viewModel.dismiss() }
                }
            }

            // Right click: modifier+right-click pins; plain right-click dismisses
            if type == .rightMouseDown && isActive {
                let modifierHeld = !pinHotkeyStr.isEmpty && event.flags.contains(pinMods.cgEventFlags)

                if modifierHeld {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.viewModel.pinCurrentPill() }
                    }
                    return nil // consume so the right-click menu doesn't appear
                } else if clickToDismiss {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.viewModel.dismiss() }
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }

        let mods = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = nsEvent.keyCode
        let characters = nsEvent.characters

        // Configurable hotkey
        let (hotkeyStr, hotkeyMods, hotkeyCode) = MainActor.assumeIsolated {
            let h = ConfigManager.shared.config.hotkey
            let (m, c) = Self.parseHotkey(h)
            return (h, m, c)
        }
        if !hotkeyStr.isEmpty && keyCode == hotkeyCode && mods == hotkeyMods {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.viewModel.drawingToggleActive {
                        if self.viewModel.pillHiddenForDrawing {
                            self.viewModel.showPubbleForDrawing()
                        } else {
                            self.viewModel.returnToDrawingMode()
                        }
                    } else if self.viewModel.isActive {
                        self.viewModel.dismiss()
                    } else {
                        self.viewModel.activate()
                    }
                }
            }
            return nil
        }

        // Drawing toggle hotkey
        let (drawToggleStr, drawToggleMods, drawToggleCode) = MainActor.assumeIsolated {
            let h = ConfigManager.shared.config.drawingToggleHotkey
            let (m, c) = Self.parseHotkey(h)
            return (h, m, c)
        }
        if !drawToggleStr.isEmpty && keyCode == drawToggleCode && mods == drawToggleMods {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.toggleDrawing() }
            }
            return nil
        }

        // Dictation toggle hotkey
        let (dictationStr, dictationMods, dictationCode) = MainActor.assumeIsolated {
            let h = ConfigManager.shared.config.dictationHotkey
            let (m, c) = Self.parseHotkey(h)
            return (h, m, c)
        }
        if !dictationStr.isEmpty && keyCode == dictationCode && mods == dictationMods {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.toggleDictation() }
            }
            return nil
        }

        // Cmd shortcuts (only when pill is active)
        if mods.contains(.command) {
            let isActive = MainActor.assumeIsolated { self.viewModel.isActive }
            if isActive {
                if keyCode == 51 { // Cmd+Delete → clear all text
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.viewModel.handleClearAll() } }
                    return nil
                }
                let cmdArrowActions: [UInt16: @MainActor () -> Void] = [
                    125: { ConfigManager.shared.cycleTheme(forward: true) },   // Cmd+Down
                    126: { ConfigManager.shared.cycleTheme(forward: false) },  // Cmd+Up
                    124: { ConfigManager.shared.adjustPillScale(increase: true) },  // Cmd+Right
                    123: { ConfigManager.shared.adjustPillScale(increase: false) }, // Cmd+Left
                ]
                if let action = cmdArrowActions[keyCode] {
                    // Theme cycle hotkeys (Cmd+Up/Down) are blocked when there are unsaved changes
                    if keyCode == 125 || keyCode == 126 {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if !ConfigManager.shared.isDirty { action() }
                            }
                        }
                    } else {
                        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
                    }
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // When pill not active, pass through — except Esc when pinned pills exist
        let isActive = MainActor.assumeIsolated { self.viewModel.isActive }
        if !isActive {
            let hasPinned = MainActor.assumeIsolated { !self.viewModel.pinnedPills.isEmpty }
            if hasPinned && nsEvent.keyCode == 53 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.viewModel.dismissAll() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Pass through any modifier combos — user's own shortcuts (Raycast, Alfred, app shortcuts, etc.)
        let actionMods: NSEvent.ModifierFlags = [.option, .control]
        if !mods.intersection(actionMods).isEmpty {
            return Unmanaged.passUnretained(event)
        }

        // Arrow keys for cursor movement
        if keyCode == 123 { // Left arrow
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.handleArrowLeft() }
            }
            return nil
        }
        if keyCode == 124 { // Right arrow
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.handleArrowRight() }
            }
            return nil
        }
        if keyCode == 126 { // Up arrow
            DispatchQueue.main.async { MainActor.assumeIsolated { self.viewModel.handleMoveLineUp() } }
            return nil
        }
        if keyCode == 125 { // Down arrow
            DispatchQueue.main.async { MainActor.assumeIsolated { self.viewModel.handleMoveLineDown() } }
            return nil
        }

        // Escape
        if keyCode == 53 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.dismissAll() }
            }
            return nil
        }
        // Enter
        if keyCode == 36 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self.viewModel.handleNewline() }
            }
            return nil
        }
        // Backspace
        if keyCode == 51 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.viewModel.handleBackspace() }
            }
            return nil
        }
        // Regular characters
        if let chars = characters, !chars.isEmpty {
            let scalar = chars.unicodeScalars.first!
            if !CharacterSet.controlCharacters.contains(scalar) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.viewModel.handleCharacter(chars) }
                }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handlePermissionLost() {
        viewModel.dismiss()
        tearDownEventTap()
        waitForPermission()
    }

    private func tearDownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        selfPtr?.release()
        selfPtr = nil
        eventTap = nil
        runLoopSource = nil
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        tearDownEventTap()
    }

    // MARK: - Hotkey parsing

    static let keyCodeMap: [String: UInt16] = [
        "/": 44, ".": 47, ",": 43, ";": 41, "'": 39, "[": 33, "]": 30,
        "\\": 42, "-": 27, "=": 24, "`": 50,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
        "space": 49, "return": 36, "tab": 48, "escape": 53,
        "delete": 51, "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Parses a hotkey string like "cmd+/" or "cmd+shift+k" into modifier flags and a key code.
    static func parseHotkey(_ hotkey: String) -> (NSEvent.ModifierFlags, UInt16) {
        let parts = hotkey.lowercased().split(separator: "+").map(String.init)
        var mods: NSEvent.ModifierFlags = []
        var code: UInt16 = 44 // default: /

        for part in parts {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "alt", "option", "opt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default:
                if let mapped = keyCodeMap[part] {
                    code = mapped
                }
            }
        }

        // Default to cmd if no modifiers specified
        if mods.isEmpty { mods = .command }

        return (mods, code)
    }
}

extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
