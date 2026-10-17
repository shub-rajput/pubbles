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
        case "draw":
            // Same as holding the drawing modifier: while on (and the bubble is active), the overlay
            // takes left-drags as strokes.
            viewModel.drawingModeEnabled = (info["on"] as? Bool) ?? false
        default:
            break // "state" (or anything unknown) just reports
        }

        var state: [String: Any] = [
            "active": viewModel.isActive,
            "pins": viewModel.pinnedPills.count,
            "drawing": viewModel.drawingModeEnabled,
        ]
        if let seq = info["seq"] { state["seq"] = seq }
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: nil, userInfo: state, deliverImmediately: true
        )
    }
}
