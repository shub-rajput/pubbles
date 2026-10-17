import AppKit

/// Runs takes: prepares the stage, counts down, plays the script with the ghost pointer and (for a
/// recording) captures just the stage. One take at a time; Esc or Stop cancels it.
@MainActor
final class TakeController {
    enum Kind { case rehearsal, recording }

    private let viewModel: SubtitleViewModel
    private let stage = Stage()
    private var task: Task<Void, Never>?

    private(set) var kind: Kind?
    private(set) var sceneLabel: String?
    private(set) var startedAt: Date?
    /// How the last take ended, in full (the bubble only has room for a short version).
    private(set) var lastResult: String?
    /// Called whenever the running state changes (for the menubar).
    var onChange: (() -> Void)?

    var isRunning: Bool { task != nil }

    init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    static var recordingsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Pubbles")
    }

    func start(id: String, version: Int, kind: Kind) {
        guard task == nil else { return }
        self.kind = kind
        sceneLabel = "Preparing"
        startedAt = nil
        onChange?()
        task = Task { await run(id: id, version: version, kind: kind) }
    }

    func stop() {
        task?.cancel()
    }

    private func run(id: String, version: Int, kind: Kind) async {
        var recorder: StageRecorder?
        var message: String
        var detail: String? = nil
        do {
            let script = try ScriptStore.load(id: id, version: version)
            viewModel.dismissAll()
            viewModel.takeInProgress = true
            try await stage.open(url: script.url, viewport: script.viewportSize)
            stage.activate()

            let start = stage.vp(script.viewportSize.width * 0.5, script.viewportSize.height * 0.55)
            let player = TakePlayer(stage: stage, viewModel: viewModel, start: start)
            player.onScene = { [weak self] i, title in
                self?.sceneLabel = "Scene \(i + 1)/\(script.scenes.count) · \(title)"
                self?.onChange?()
            }

            if kind == .recording {
                try await countdown()
                try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
                let stamp = Self.stampFormatter.string(from: Date())
                recorder = StageRecorder(url: Self.recordingsFolder.appendingPathComponent("\(id)-v\(version)-\(stamp).mov"))
                try await recorder?.start(stageRect: stage.screenRect, stagePID: stage.chromePID)
                try await Task.sleep(for: .milliseconds(300)) // a beat of stillness before the first move
            }
            startedAt = Date()
            onChange?()

            try await player.play(script)
            let length = Date().timeIntervalSince(startedAt ?? Date())
            message = kind == .recording ? "take saved · \(Self.clock(length))" : "rehearsal ok · \(Self.clock(length))"
        } catch is CancellationError {
            message = recorder?.startedAt == nil ? "take stopped" : "stopped · partial saved"
        } catch {
            message = "take stopped · see menu"
            detail = error.localizedDescription
        }

        await recorder?.stop()
        let saved = recorder?.startedAt != nil ? recorder?.url.lastPathComponent : nil
        lastResult = [detail ?? message, saved.map { "Saved to \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")

        // Say how it went where the ghost pointer is, then hand the screen back.
        viewModel.dismissAll()
        try? await Task.sleep(for: .milliseconds(350))
        viewModel.activate()
        for ch in message { viewModel.handleCharacter(String(ch)) }
        try? await Task.sleep(for: .seconds(2.5))
        viewModel.dismissAll()
        viewModel.hideGhost()
        viewModel.takeInProgress = false

        task = nil
        self.kind = nil
        sceneLabel = nil
        startedAt = nil
        onChange?()
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

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
