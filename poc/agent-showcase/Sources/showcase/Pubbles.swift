import AppKit
import Foundation

/// Drives Pubbles through its agent control channel (`AgentControl.swift` in the app): distributed
/// notifications in, a state reply for every command out. No hotkeys are faked, so the user's
/// shortcut config and app shortcut clashes (cmd+p = Print, cmd+l = address bar) don't matter.
final class Pubbles {
    static let commandName = Notification.Name("app.pubbles.agent")
    static let stateName = Notification.Name("app.pubbles.agent.state")

    struct State {
        var active = false
        var pins = 0
        var drawing = false
    }

    let dry: Bool
    private(set) var state = State()
    private var seq = 0
    private var lastReply: [AnyHashable: Any]?
    private var observer: NSObjectProtocol?

    var clickToDismiss = false
    var idleTimeout = 10.0

    init(dry: Bool) {
        self.dry = dry
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.stateName, object: nil, queue: nil) { [weak self] note in
            self?.lastReply = note.userInfo
        }
        loadConfig()
    }

    static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Pubbles" }
    }

    /// Send one command and wait for Pubbles to confirm it, updating `state`.
    @discardableResult
    func send(_ cmd: String, _ extra: [String: Any] = [:], timeout: Double = 1.5) throws -> State {
        if dry {
            switch cmd {
            case "show": state.active = true
            case "hide": state.active = false
            case "dismissAll": state = State()
            case "pin": state.pins += 1
            case "draw": state.drawing = (extra["on"] as? Bool) ?? false
            default: break
            }
            return state
        }
        seq += 1
        var info = extra
        info["cmd"] = cmd
        info["seq"] = seq
        lastReply = nil
        DistributedNotificationCenter.default().postNotificationName(Self.commandName, object: nil, userInfo: info, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
            if let r = lastReply, (r["seq"] as? Int) == seq {
                state = State(active: r["active"] as? Bool ?? false, pins: r["pins"] as? Int ?? 0, drawing: r["drawing"] as? Bool ?? false)
                return state
            }
        }
        throw DriverError.preflight("Pubbles didn't answer \"\(cmd)\"; is it a build with agent control? (./scripts/build.sh)")
    }

    private func loadConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pubbles/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let behavior = cfg["behavior"] as? [String: Any] ?? [:]
        if let v = behavior["clickToDismiss"] as? Bool { clickToDismiss = v }
        if let v = (behavior["idleTimeout"] as? NSNumber)?.doubleValue { idleTimeout = v }
    }

    /// Things in the user's config that would make a take misbehave.
    func warnings() -> [String] {
        var w: [String] = []
        if idleTimeout > 0 { w.append("idleTimeout is \(idleTimeout)s; a bubble left idle that long will fade on its own") }
        if clickToDismiss { w.append("clickToDismiss is on; clicks will close the bubble") }
        return w
    }
}

func log(_ message: String) {
    let stamp = String(format: "%6.2f", Date().timeIntervalSince(launchTime))
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

let launchTime = Date()
