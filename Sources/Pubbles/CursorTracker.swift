import AppKit

@MainActor
final class CursorTracker {
    private var timer: Timer?
    private let viewModel: SubtitleViewModel

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                guard !self.viewModel.ghostCursorActive else { return }
                let mouseLocation = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
                    ?? NSScreen.main
                guard let screen = screen else { return }
                let localX = mouseLocation.x - screen.frame.origin.x
                let localY = screen.frame.height - (mouseLocation.y - screen.frame.origin.y)
                let newPos = NSPoint(x: localX, y: localY)
                if newPos != self.viewModel.cursorPosition {
                    self.viewModel.cursorPosition = newPos
                }
                let newScreenID = ObjectIdentifier(screen)
                if newScreenID != self.viewModel.activeScreenID {
                    self.viewModel.activeScreenID = newScreenID
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
