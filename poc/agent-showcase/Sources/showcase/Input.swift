import CoreGraphics
import Foundation

enum DriverError: Error, CustomStringConvertible {
    case aborted(String)
    case cdp(String)
    case preflight(String)
    case target(String)
    case script(String)

    var description: String {
        switch self {
        case .aborted(let m): return "Aborted: \(m)"
        case .cdp(let m): return "Chrome: \(m)"
        case .preflight(let m): return "Preflight: \(m)"
        case .target(let t): return "Target not found on the page: \(t)"
        case .script(let m): return "Script: \(m)"
        }
    }
}

/// Where pointer motion goes instead of the real mouse (ghost mode).
protocol PointerSink: AnyObject {
    func move(_ p: CGPoint, drawing: Bool)
    func penDown(_ p: CGPoint)
    func penUp(_ p: CGPoint)
    func wheel(_ dy: Int32, at p: CGPoint)
}

/// Posts real macOS mouse + keyboard events (needs Accessibility permission for the terminal),
/// or, with a `sink`, hands pointer motion to a ghost pointer and leaves the real mouse alone.
/// Tracks where it last put the cursor so it can tell when a human grabs the mouse, and stops.
/// Everything it posts is stamped with `KeyWatcher.marker` so the Esc watcher ignores it.
final class Input {
    let source = CGEventSource(stateID: .hidSystemState)
    private(set) var pos: CGPoint
    private var prevPos: CGPoint
    private(set) var cmdHeld = false
    private(set) var buttonDown = false
    var dry = false
    var watchForHuman = true
    /// Ghost mode: pointer events go here; the real mouse is the user's.
    weak var sink: PointerSink?
    private var strikes = 0

    init() {
        let p = CGEvent(source: nil)?.location ?? .zero
        pos = p
        prevPos = p
    }

    // MARK: Safety

    /// Abort if Esc was pressed, or (when driving the real cursor) if it's far from where we last
    /// put it (someone moved the mouse).
    func checkAbort() throws {
        guard !dry else { return }
        if keyWatcher.stopRequested { throw DriverError.aborted("Esc pressed") }
        guard watchForHuman, sink == nil else { return }
        let actual = CGEvent(source: nil)?.location ?? pos
        let off = min(hypot(actual.x - pos.x, actual.y - pos.y), hypot(actual.x - prevPos.x, actual.y - prevPos.y))
        // Two off-track readings in a row = a human grabbed the mouse.
        strikes = off > 90 ? strikes + 1 : 0
        if strikes >= 2 {
            throw DriverError.aborted("cursor at (\(Int(actual.x)), \(Int(actual.y))) but expected (\(Int(pos.x)), \(Int(pos.y))); was the mouse moved by hand?")
        }
    }

    func sleep(_ seconds: Double) {
        guard !dry, seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Mouse

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
        prevPos = pos
        pos = p
        guard !dry else { return }
        if let sink {
            switch type {
            case .mouseMoved: sink.move(p, drawing: false)
            case .leftMouseDragged: sink.move(p, drawing: true)
            case .leftMouseDown: sink.penDown(p)
            case .leftMouseUp: sink.penUp(p)
            default: break
            }
            return
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: KeyWatcher.marker)
        e.flags = cmdHeld ? .maskCommand : []
        if type != .mouseMoved && type != .leftMouseDragged {
            e.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        e.post(tap: .cghidEventTap)
    }

    /// One frame of motion; emits a drag while the button is held.
    func move(_ p: CGPoint) throws {
        try checkAbort()
        post(buttonDown ? .leftMouseDragged : .mouseMoved, p)
    }

    /// Teleport without the human-check (used once to place the cursor before a take).
    func warp(_ p: CGPoint) {
        post(.mouseMoved, p)
        prevPos = p
    }

    func leftDown() { post(.leftMouseDown, pos); buttonDown = true }
    func leftUp() { post(.leftMouseUp, pos); buttonDown = false }

    func click() {
        leftDown()
        sleep(0.05)
        leftUp()
    }

    func rightClick() {
        post(.rightMouseDown, pos, button: .right)
        sleep(0.05)
        post(.rightMouseUp, pos, button: .right)
    }

    // MARK: Scroll

    /// One frame of trackpad-style (pixel, continuous) scrolling at the current cursor position.
    /// Positive `dy` moves the content up, i.e. scrolls the page down (sign is calibrated by Player).
    func scroll(_ dy: Int32) {
        guard !dry, dy != 0 else { return }
        if let sink { sink.wheel(dy, at: pos); return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -dy, wheel2: 0, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: KeyWatcher.marker)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.location = pos
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    func setCmd(_ on: Bool) {
        cmdHeld = on
        guard !dry, let e = CGEvent(keyboardEventSource: source, virtualKey: Keys.command, keyDown: on) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: KeyWatcher.marker)
        e.type = .flagsChanged
        e.flags = on ? .maskCommand : []
        e.post(tap: .cghidEventTap)
    }

    func press(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil) {
        guard !dry else { return }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: KeyWatcher.marker)
            e.flags = flags.union(cmdHeld ? .maskCommand : [])
            if let text {
                let utf16 = Array(text.utf16)
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            e.post(tap: .cghidEventTap)
            if down { Thread.sleep(forTimeInterval: 0.012) }
        }
    }

    func hotkey(_ hk: Hotkey) { press(hk.key, hk.flags) }

    func typeChar(_ ch: Character) {
        let s = String(ch)
        if let (code, shift) = Keys.code(for: ch) {
            press(code, shift ? .maskShift : [], text: s)
        } else {
            press(0, [], text: s)
        }
    }

    /// Release anything we might be holding. Safe to call any time.
    func releaseAll() {
        if buttonDown { leftUp() }
        if cmdHeld { setCmd(false) }
    }
}

struct Hotkey {
    let flags: CGEventFlags
    let key: CGKeyCode
}

enum Keys {
    static let command: CGKeyCode = 0x37
    static let returnKey: CGKeyCode = 36
    static let delete: CGKeyCode = 51
    static let escape: CGKeyCode = 53
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126

    // US ANSI layout.
    private static let base: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        " ": 49, "`": 50,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func code(for ch: Character) -> (CGKeyCode, Bool)? {
        if let c = base[ch] { return (c, false) }
        if ch.isUppercase, let c = base[Character(ch.lowercased())] { return (c, true) }
        if let b = shifted[ch], let c = base[b] { return (c, true) }
        return nil
    }

    /// Parse Pubbles-style hotkeys like "cmd+p", "cmd+shift+/".
    static func parse(_ s: String) -> Hotkey? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in s.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                if let ch = part.first, part.count == 1 { key = code(for: ch)?.0 }
            }
        }
        guard let key else { return nil }
        return Hotkey(flags: flags, key: key)
    }
}
