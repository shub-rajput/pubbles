import AppKit

/// Lets local scripts and agents drive Pubbles directly instead of faking its hotkeys
/// (proof of concept for "Pubbles for agents", see docs/ideas/2026-10-12-pubbles-for-agents.md).
///
/// Commands arrive as distributed notifications named `app.pubbles.agent` with a `cmd` key in
/// userInfo. Every command is answered with `app.pubbles.agent.state`, echoing its `seq` and the
/// resulting bubble state, so callers can wait for each command to land.
@MainActor
final class AgentControl: NSObject {
    static let commandName = Notification.Name("app.pubbles.agent")
    static let stateName = Notification.Name("app.pubbles.agent.state")

    private let viewModel: SubtitleViewModel
    /// Start a take: script id, version, record (vs rehearse). Set by the app delegate.
    var onTake: ((String, Int, Bool) -> Void)?
    var onStopTake: (() -> Void)?
    /// Running take / last result, included in every state reply.
    var takeStatus: (() -> [String: Any])?

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handle(_:)), name: Self.commandName, object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handle(_ note: Notification) {
        let info = note.userInfo ?? [:]
        switch info["cmd"] as? String {
        case "show":
            if !viewModel.isActive { viewModel.activate() }
        case "hide":
            if viewModel.isActive { viewModel.dismiss() }
        case "dismissAll":
            viewModel.dismissAll()
        case "type":
            for ch in (info["text"] as? String) ?? "" { viewModel.handleCharacter(String(ch)) }
        case "newline":
            if viewModel.isActive { _ = viewModel.handleNewline() }
        case "backspace":
            viewModel.handleBackspace()
        case "clear":
            viewModel.handleClearAll()
        case "pin":
            viewModel.pinCurrentPill()
        case "ghost":
            // Move the ghost pointer (and with it the bubble) without touching the real mouse.
            if let p = globalPoint(info) { viewModel.moveGhost(to: p) }
        case "ghostOff":
            viewModel.hideGhost()
        case "strokeBegin":
            if let p = globalPoint(info) { viewModel.ghostStrokeBegin(at: p) }
        case "strokeTo":
            if let p = globalPoint(info) { viewModel.ghostStrokeTo(p) }
        case "strokeEnd":
            viewModel.endStroke()
        case "clearStrokes":
            viewModel.clearStrokesAnimated()
        case "take":
            if let id = info["id"] as? String {
                let version = (info["version"] as? NSNumber)?.intValue ?? ScriptStore.list().first { $0.id == id }?.latest ?? 1
                onTake?(id, version, info["record"] as? Bool ?? false)
            }
        case "stopTake":
            onStopTake?()
        case "draw":
            // Same as holding the drawing modifier: while on (and the bubble is active), the overlay
            // takes left-drags as strokes.
            viewModel.drawingModeEnabled = (info["on"] as? Bool) ?? false
        default:
            break // "state" (or anything unknown) just reports
        }

        if info["quiet"] as? Bool == true { return } // per-frame commands don't need an answer

        var state: [String: Any] = [
            "active": viewModel.isActive,
            "pins": viewModel.pinnedPills.count,
            "drawing": viewModel.drawingModeEnabled,
            "strokes": viewModel.strokes.count,
        ]
        if let seq = info["seq"] { state["seq"] = seq }
        if let take = takeStatus?() { state["take"] = take }
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: nil, userInfo: state, deliverImmediately: true
        )
    }

    /// `x`/`y` in global CoreGraphics coordinates (top-left of the main display).
    private func globalPoint(_ info: [AnyHashable: Any]) -> CGPoint? {
        guard let x = (info["x"] as? NSNumber)?.doubleValue, let y = (info["y"] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }
}
