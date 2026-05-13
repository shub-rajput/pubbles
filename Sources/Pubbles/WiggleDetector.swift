import AppKit
import Combine

/// Detects a rapid back-and-forth "wiggle" of the mouse cursor.
///
/// Subscribes to `SubtitleViewModel.cursorPosition` (updated 60×/sec by `CursorTracker`).
/// Tracks horizontal direction reversals within a sliding time window. When the number of
/// reversals AND the cumulative travel distance both exceed sensitivity-derived thresholds,
/// fires `onWiggle`. Suppressed while a pubble is visible.
@MainActor
final class WiggleDetector {
    /// Set this whenever `config.behavior.wiggleSensitivity` changes.
    var sensitivity: Sensitivity = .medium

    /// Called when a wiggle is detected. AppDelegate dispatches based on current mode.
    var onWiggle: (() -> Void)?

    private let viewModel: SubtitleViewModel
    private var cancellables: Set<AnyCancellable> = []

    /// (x-position, timestamp) samples within the current window.
    private var samples: [(x: CGFloat, t: TimeInterval)] = []
    /// Earliest time we'll fire again after a successful trigger.
    private var cooldownUntil: TimeInterval = 0

    private static let cooldown: TimeInterval = 0.5
    /// Below this much horizontal motion between samples, treat as noise (no reversal counted).
    private static let minDeltaToCount: CGFloat = 2

    enum Sensitivity: String {
        case low, medium, high

        var minReversals: Int {
            switch self {
            case .low: return 5
            case .medium: return 4
            case .high: return 3
            }
        }

        var minTravel: CGFloat {
            switch self {
            case .low: return 420
            case .medium: return 300
            case .high: return 200
            }
        }

        var windowDuration: TimeInterval {
            switch self {
            case .low: return 0.40
            case .medium: return 0.45
            case .high: return 0.50
            }
        }
    }

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        cancellables.removeAll()

        viewModel.$cursorPosition
            .sink { [weak self] point in
                self?.observe(x: point.x)
            }
            .store(in: &cancellables)

        // Clear buffer whenever a pubble appears so motion during a visible pubble doesn't count
        viewModel.$isVisible
            .sink { [weak self] visible in
                if visible { self?.samples.removeAll() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        samples.removeAll()
    }

    private func observe(x: CGFloat) {
        guard !viewModel.isVisible else { return }

        let now = CACurrentMediaTime()
        if now < cooldownUntil { return }

        let cutoff = now - sensitivity.windowDuration
        while let oldest = samples.first, oldest.t < cutoff {
            samples.removeFirst()
        }
        samples.append((x: x, t: now))

        // Recompute over the current window — buffer is small (~27 samples at 60 FPS × 0.45 s).
        var reversals = 0
        var travel: CGFloat = 0
        var lastDirection = 0
        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            if abs(dx) < Self.minDeltaToCount { continue }
            let dir = dx > 0 ? 1 : -1
            if lastDirection != 0 && dir != lastDirection {
                reversals += 1
            }
            lastDirection = dir
            travel += abs(dx)
        }

        if reversals >= sensitivity.minReversals && travel >= sensitivity.minTravel {
            cooldownUntil = now + Self.cooldown
            samples.removeAll()
            onWiggle?()
        }
    }
}
