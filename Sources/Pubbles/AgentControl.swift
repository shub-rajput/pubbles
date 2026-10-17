import AppKit
import SwiftUI

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
        case "ghost":
            // Move the ghost pointer (and with it the bubble) without touching the real mouse.
            guard let p = localPoint(info) else { break }
            viewModel.ghostCursorActive = true
            moveGhost(to: p)
        case "ghostOff":
            viewModel.ghostCursorActive = false
        case "strokeBegin":
            // Ghost doodles go straight into the stroke list, so the overlay never has to take the
            // real mouse (no drawing mode, nothing blocked for the user).
            guard viewModel.isActive, let p = localPoint(info) else { break }
            moveGhost(to: p)
            viewModel.currentStroke = [p.point]
            viewModel.isDrawing = true
        case "strokeTo":
            guard !viewModel.currentStroke.isEmpty, let p = localPoint(info) else { break }
            moveGhost(to: p)
            viewModel.currentStroke.append(p.point)
        case "strokeEnd":
            viewModel.endStroke()
        case "clearStrokes":
            // Doodles are screen-anchored, so callers clear them before scrolling the content away
            withAnimation(.easeOut(duration: 0.25)) { viewModel.clearStrokes() }
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
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: nil, userInfo: state, deliverImmediately: true
        )
    }

    /// `x`/`y` in global CoreGraphics coordinates (top-left of the main display) → the screen they
    /// fall on and a point local to it, matching what CursorTracker produces for the real mouse.
    private func localPoint(_ info: [AnyHashable: Any]) -> (point: NSPoint, screen: NSScreen)? {
        guard let x = (info["x"] as? NSNumber)?.doubleValue, let y = (info["y"] as? NSNumber)?.doubleValue,
              let primary = NSScreen.screens.first else { return nil }
        let global = NSPoint(x: x, y: primary.frame.height - y)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(global, $0.frame, false) }) ?? NSScreen.main else { return nil }
        let local = NSPoint(x: global.x - screen.frame.origin.x, y: screen.frame.height - (global.y - screen.frame.origin.y))
        return (local, screen)
    }

    private func moveGhost(to p: (point: NSPoint, screen: NSScreen)) {
        if viewModel.cursorPosition != p.point { viewModel.cursorPosition = p.point }
        let id = ObjectIdentifier(p.screen)
        if viewModel.activeScreenID != id { viewModel.activeScreenID = id }
    }
}
