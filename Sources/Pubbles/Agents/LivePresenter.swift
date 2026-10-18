import AppKit

/// Live mode: an agent points and explains on any part of the screen, one call at a time, with the
/// ghost pointer, bubbles and doodles. Pubbles doesn't need to understand the app underneath; the
/// agent finds positions itself (e.g. with a computer-use tool). Nothing is recorded.
///
/// Positions are global screen points, top-left of the main display (the space macOS Accessibility
/// frames use). Calls run one after another. Esc, `end()`, a take starting, or a minute without
/// calls ends it.
@MainActor
final class LivePresenter {
    private let viewModel: SubtitleViewModel
    private var motion: GhostMotion?
    private var last: Task<Void, Error>?
    private var idleTimer: Timer?
    /// Where arranged windows were before, so live_end can put them back.
    private var movedWindows: [(AXUIElement, CGRect)] = []
    private static let idleTimeout: TimeInterval = 60

    var isActive: Bool { motion != nil }

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    // MARK: Actions

    /// Bring several apps' windows forward together, laid out so all can be seen (for explaining
    /// something that spans apps). They go back where they were when live mode ends.
    func arrange(_ windows: [(app: String, title: String?)], layout: WindowFocus.Layout) async throws -> [(String, WindowFocus.State)] {
        var result: [(String, WindowFocus.State)] = []
        try await serial { _ in
            var targets: [WindowFocus.Target] = []
            for w in windows { targets.append(try await WindowFocus.resolve(app: w.app, title: w.title)) }
            let (states, previous) = try await WindowFocus.arrange(targets, layout: layout)
            // Keep the earliest known position of each window across repeated arranges.
            for (window, frame) in previous where !self.movedWindows.contains(where: { CFEqual($0.0, window) }) {
                self.movedWindows.append((window, frame))
            }
            result = zip(targets.map(\.name), states).map { ($0, $1) }
        }
        return result
    }

    /// Bring the app (and window) the agent is explaining to the front, so the user sees what the
    /// pointer is pointing at. Returns where that window is and whether it's visible.
    @discardableResult
    func focus(app: String, title: String?) async throws -> WindowFocus.State {
        var state = WindowFocus.State()
        try await serial { _ in state = try await WindowFocus.focus(app: app, title: title) }
        return state
    }

    func point(at p: CGPoint, duration: Double?) async throws {
        try await serial { try await $0.glide(to: p, duration: duration) }
    }

    /// A new message in the bubble (replacing what was there), optionally after gliding to `at`.
    func say(_ text: String, at p: CGPoint?) async throws {
        try await serial { motion in
            if let p { try await motion.glide(to: p) }
            if self.viewModel.isActive { self.viewModel.handleClearAll() }
            try await motion.say(text)
        }
    }

    func circle(_ r: CGRect, duration: Double?) async throws {
        try await serial { try await $0.doodle([Shapes.ellipse(around: r, pad: 12)], durations: [duration ?? 0.9]) }
    }

    func underline(_ r: CGRect, duration: Double?) async throws {
        try await serial { try await $0.doodle([Shapes.underline(r)], durations: [duration ?? 0.35]) }
    }

    func arrow(to tip: CGPoint, from start: CGPoint?) async throws {
        let start = start ?? CGPoint(x: tip.x - 170, y: tip.y - 90)
        try await serial { try await $0.doodle(Shapes.arrow(from: start, to: tip), durations: [0.45, 0.12, 0.12]) }
    }

    func pin() async throws {
        try await serial { _ in
            guard self.viewModel.isActive, !self.viewModel.text.isEmpty else {
                throw TakeError.script("Nothing to pin; say something first")
            }
            self.viewModel.pinCurrentPill()
        }
    }

    /// Clear the bubble's text and the doodles; pins stay.
    func clear() async throws {
        try await serial { _ in
            if self.viewModel.isActive { self.viewModel.handleClearAll() }
            self.viewModel.clearStrokesAnimated()
        }
    }

    /// Bubble off (pins stay); the pointer stays up.
    func hideBubble() async throws {
        try await serial { _ in
            if self.viewModel.isActive { self.viewModel.dismiss() }
        }
    }

    /// Everything off: bubble, pins, doodles and the ghost pointer. The user's input is theirs again.
    func end() {
        last?.cancel()
        last = nil
        idleTimer?.invalidate()
        idleTimer = nil
        WindowFocus.restore(movedWindows)
        movedWindows = []
        guard motion != nil else { return }
        motion = nil
        viewModel.dismissAll()
        viewModel.hideGhost()
        viewModel.takeInProgress = false
    }

    // MARK: Plumbing

    /// Run one action after the previous one finishes, starting the session if needed.
    private func serial(_ action: @escaping @MainActor (GhostMotion) async throws -> Void) async throws {
        let motion = begin()
        resetIdleTimer()
        let previous = last
        let task = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            try await action(motion)
        }
        last = task
        try await task.value
        resetIdleTimer()
    }

    private func begin() -> GhostMotion {
        if let motion { return motion }
        // Start where the user's real pointer is, so the ghost appears from somewhere sensible.
        let start = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 400)
        viewModel.takeInProgress = true // keys, clicks and wiggles stay the user's
        let motion = GhostMotion(viewModel: viewModel, start: start)
        self.motion = motion
        return motion
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }
}
