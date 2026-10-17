import AppKit
import SwiftUI

/// The ghost pointer and ghost strokes: how agents point and doodle without touching the real
/// mouse. Points are global CoreGraphics coordinates (top-left of the main display, the space
/// DevTools and CGEvent use); they're converted to the screen-local space CursorTracker produces.
extension SubtitleViewModel {
    func moveGhost(to global: CGPoint) {
        guard let target = Self.localPoint(global) else { return }
        ghostCursorActive = true
        if cursorPosition != target.point { cursorPosition = target.point }
        let id = ObjectIdentifier(target.screen)
        if activeScreenID != id { activeScreenID = id }
    }

    func hideGhost() {
        ghostCursorActive = false
    }

    /// Strokes go straight into the stroke list, so the overlay never has to take the real mouse
    /// (no drawing mode, nothing blocked for the user). Needs an active bubble, like real doodles.
    func ghostStrokeBegin(at global: CGPoint) {
        guard isActive, let target = Self.localPoint(global) else { return }
        moveGhost(to: global)
        currentStroke = [target.point]
        isDrawing = true
    }

    func ghostStrokeTo(_ global: CGPoint) {
        guard !currentStroke.isEmpty, let target = Self.localPoint(global) else { return }
        moveGhost(to: global)
        currentStroke.append(target.point)
    }

    /// Doodles are screen-anchored, so they're cleared before the content under them scrolls away.
    func clearStrokesAnimated() {
        withAnimation(.easeOut(duration: 0.25)) { clearStrokes() }
    }

    static func localPoint(_ global: CGPoint) -> (point: NSPoint, screen: NSScreen)? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = NSPoint(x: global.x, y: primary.frame.height - global.y)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(flipped, $0.frame, false) }) ?? NSScreen.main else { return nil }
        let local = NSPoint(x: flipped.x - screen.frame.origin.x,
                            y: screen.frame.height - (flipped.y - screen.frame.origin.y))
        return (local, screen)
    }
}
