import CoreGraphics
import Foundation

/// Watches the physical keyboard during a take: Esc stops it, Return answers the ready prompt.
/// A listen-only tap at the HID level, on its own thread, so it sees keys before Pubbles (which
/// swallows Esc/Return while a bubble is up) and works while the player's main thread sleeps.
/// Events the player posts itself carry `marker` and are ignored.
final class KeyWatcher {
    static let marker: Int64 = 0x5055_4242 // "PUBB"

    private let lock = NSLock()
    private var _stop = false
    private var _go = false

    var stopRequested: Bool { lock.withLock { _stop } }
    var goRequested: Bool { lock.withLock { _go } }

    func resetGo() { lock.withLock { _go = false } }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var failed = false
        let thread = Thread {
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard type == .keyDown, let refcon,
                      event.getIntegerValueField(.eventSourceUserData) != KeyWatcher.marker else {
                    return Unmanaged.passUnretained(event)
                }
                let watcher = Unmanaged<KeyWatcher>.fromOpaque(refcon).takeUnretainedValue()
                switch event.getIntegerValueField(.keyboardEventKeycode) {
                case 53: watcher.lock.withLock { watcher._stop = true }       // Esc
                case 36, 76: watcher.lock.withLock { watcher._go = true }     // Return / keypad Enter
                default: break
                }
                return Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                failed = true
                ready.signal()
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        ready.wait()
        if failed { throw DriverError.preflight("couldn't watch the keyboard for Esc (Accessibility / Input Monitoring for this terminal?)") }
    }
}

let keyWatcher = KeyWatcher()
