import AppKit

/// Runs takes: prepares the stage, counts down, plays the script with the ghost pointer and (for a
/// recording) captures just the stage. One take at a time; Esc or Stop cancels it.
@MainActor
final class TakeController {
    enum Kind: String { case rehearsal, recording, preview }

    struct Result: Sendable {
        var kind: String
        var script: String
        var version: Int
        var finished: Bool   // played to the end
        var stopped: Bool    // Esc / Stop
        var error: String?   // why it couldn't finish (scene and step included)
        var errorCode: String? // e.g. stage_not_visible, stage_occluded, stage_lost, stage_moved
        var seconds: Double
        var file: String?    // recording path
        var stageAtStart: Stage.WindowState?
        var coveredDuringTake = false
        var snapshot: Data?  // preview: JPEG of the stage with bubbles, pins and doodles

        var summary: String {
            var parts = [finished ? "\(kind) finished" : stopped ? "\(kind) stopped" : "\(kind) failed",
                         TakeController.clock(seconds)]
            if let error { parts.append(error) }
            if let file { parts.append("saved to \((file as NSString).lastPathComponent)") }
            return parts.joined(separator: " · ")
        }
    }

    private let viewModel: SubtitleViewModel
    /// The stage, shared with agent tools (they explore it between takes).
    let stage = Stage()
    private var task: Task<Void, Never>?
    /// Set by the stage guard before it cancels a take, so the result says why.
    private var abortReason: (code: String, message: String)?
    private var waiters: [CheckedContinuation<Result, Never>] = []

    private(set) var kind: Kind?
    private(set) var sceneLabel: String?
    private(set) var startedAt: Date?
    private(set) var lastTake: Result?
    /// Called whenever the running state changes (for the menubar).
    var onChange: (() -> Void)?

    var isRunning: Bool { task != nil }
    var lastResult: String? { lastTake?.summary }

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    static var recordingsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Pubbles")
    }

    /// Start a take; false if one is already running.
    @discardableResult
    func start(id: String, version: Int, kind: Kind, throughScene: Int? = nil) -> Bool {
        guard task == nil else { return false }
        self.kind = kind
        sceneLabel = "Preparing"
        startedAt = nil
        onChange?()
        task = Task { await run(id: id, version: version, kind: kind, throughScene: throughScene) }
        return true
    }

    /// Wait for the running take to end (returns the last result right away if none is running).
    func waitForEnd() async -> Result? {
        guard task != nil else { return lastTake }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func stop() {
        task?.cancel()
    }

    private func run(id: String, version: Int, kind: Kind, throughScene: Int? = nil) async {
        var recorder: StageRecorder?
        var stageGuard: Task<Void, Never>?
        var movedWindows: [(AXUIElement, CGRect)] = []
        var result = Result(kind: kind.rawValue, script: id, version: version, finished: false, stopped: false, seconds: 0)
        var message: String
        abortReason = nil
        do {
            let script = try ScriptStore.load(id: id, version: version)
            viewModel.dismissAll()
            viewModel.takeInProgress = true
            // Set the scene: the stage for a web script, the arranged windows for an app script.
            let region: CGRect
            let shown: [StageRecorder.Shown]
            var webStage: Stage?
            if let windows = script.windows, !windows.isEmpty {
                var targets: [WindowFocus.Target] = []
                for w in windows { targets.append(try await WindowFocus.resolve(app: w.app, title: w.title)) }
                let layout = WindowFocus.Layout(rawValue: script.layout ?? "side_by_side") ?? .sideBySide
                let arranged = try await WindowFocus.arrange(targets, layout: layout)
                movedWindows = arranged.previous
                shown = zip(targets, arranged.states).compactMap { t, s in s.frame.map { (t.pid, $0) } }
                region = shown.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                result.stageAtStart = arranged.states.first
            } else {
                try await stage.open(url: script.url ?? "", viewport: script.viewportSize, forTake: true)
                webStage = stage
                shown = [(stage.chromePID, stage.screenRect)]
                region = stage.screenRect
                result.stageAtStart = stage.windowState()
            }
            stageGuard = guardWindows(shown) { result.coveredDuringTake = true }

            let start = CGPoint(x: region.midX, y: region.minY + region.height * 0.55)
            let player = TakePlayer(stage: webStage, viewModel: viewModel, start: start, bounds: region)
            player.onScene = { [weak self] i, title in
                self?.sceneLabel = "Scene \(i + 1)/\(script.scenes.count) · \(title)"
                self?.onChange?()
            }

            if kind == .recording {
                try await countdown()
                try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
                let stamp = Self.stampFormatter.string(from: Date())
                recorder = StageRecorder(url: Self.recordingsFolder.appendingPathComponent("\(id)-v\(version)-\(stamp).mov"))
                try await recorder?.start(region: region, windows: shown)
                try await Task.sleep(for: .milliseconds(300)) // a beat of stillness before the first move
            }
            startedAt = Date()
            onChange?()

            try await player.play(script, through: throughScene)
            if kind == .preview {
                try await Task.sleep(for: .milliseconds(400)) // let the last bubble and doodle settle
                let image = try await StageRecorder.snapshot(region: region, windows: shown)
                result.snapshot = try Stage.jpeg(NSImage(cgImage: image, size: region.size), width: 960)
            }
            result.finished = true
            message = kind == .recording ? "take saved" : kind == .preview ? "preview ok" : "rehearsal ok"
        } catch is CancellationError where abortReason != nil {
            result.error = abortReason?.message
            result.errorCode = abortReason?.code
            message = "take stopped · see menu"
        } catch is CancellationError {
            result.stopped = true
            message = recorder?.startedAt == nil ? "take stopped" : "stopped · partial saved"
        } catch {
            result.error = error.localizedDescription
            result.errorCode = (error as? TakeError)?.code
            message = "take stopped · see menu"
        }
        stageGuard?.cancel()

        result.seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        await recorder?.stop()
        if recorder?.startedAt != nil { result.file = recorder?.url.path }
        if result.finished { message += " · \(Self.clock(result.seconds))" }

        // Say how it went where the ghost pointer is, then hand the screen back.
        viewModel.dismissAll()
        try? await Task.sleep(for: .milliseconds(350))
        viewModel.activate()
        for ch in message { viewModel.handleCharacter(String(ch)) }
        try? await Task.sleep(for: .seconds(2.5))
        viewModel.dismissAll()
        viewModel.hideGhost()
        viewModel.takeInProgress = false
        WindowFocus.restore(movedWindows) // an app script's windows go back where they were

        lastTake = result
        task = nil
        self.kind = nil
        sceneLabel = nil
        startedAt = nil
        onChange?()
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: result) }
    }

    /// Watch the take's windows while it plays. Minimised, closed, moved to another Space, moved or
    /// resized: stop with a reason (the pointer and recording depend on where they are). Covered:
    /// keep going (the recording only captures the take's windows) but note it.
    private func guardWindows(_ shown: [StageRecorder.Shown], onCovered: @escaping () -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                for (pid, fitted) in shown {
                    let state = WindowFocus.state(pid: pid, near: fitted)
                    if state.covered > 0.05 { onCovered() }
                    var reason: (String, String)?
                    if !state.onScreen {
                        reason = ("stage_lost", "A window in the take was minimised, closed or moved to another Space")
                    } else if let f = state.frame,
                              abs(f.minX - fitted.minX) > 4 || abs(f.minY - fitted.minY) > 4 || abs(f.width - fitted.width) > 4 {
                        reason = ("stage_moved", "A window in the take was moved or resized")
                    }
                    if let reason {
                        self.abortReason = reason
                        self.task?.cancel()
                        return
                    }
                }
            }
        }
    }

    /// 3-2-1 in a bubble at the ghost pointer, before the recording starts (so it's not in the video).
    private func countdown() async throws {
        viewModel.activate()
        for n in [3, 2, 1] {
            viewModel.handleClearAll()
            for ch in "starting in \(n)" { viewModel.handleCharacter(String(ch)) }
            try await Task.sleep(for: .seconds(1))
        }
        viewModel.dismissAll()
        try await Task.sleep(for: .milliseconds(500)) // let it fade
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
