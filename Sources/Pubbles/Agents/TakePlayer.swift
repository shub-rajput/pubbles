import AppKit

/// Plays a script with the ghost pointer: Pubbles draws the pointer, bubbles and doodles itself.
/// Web scripts play on the stage, whose page gets hover, clicks, wheel and keys over DevTools; app
/// scripts point at elements in native apps, found through Accessibility. The user's real mouse and
/// keyboard are never touched. Cancelling the task stops the take at the next frame.
@MainActor
final class TakePlayer {
    let stage: Stage?
    let viewModel: SubtitleViewModel
    /// Called when a scene starts (index, title).
    var onScene: ((Int, String) -> Void)?

    private let motion: GhostMotion
    private var pos: CGPoint { motion.pos }
    private var scrollSign = 1.0
    private var scrollCalibrated = false

    /// The pointer stays inside `bounds` (the stage, or the arranged windows).
    init(stage: Stage?, viewModel: SubtitleViewModel, start: CGPoint, bounds: CGRect) {
        self.stage = stage
        self.viewModel = viewModel
        motion = GhostMotion(viewModel: viewModel, start: start, bounds: bounds)
        if let stage {
            motion.onHover = { p in Task { try? await stage.mouse("mouseMoved", at: p) } } // the page feels it hover
        }
    }

    private func requireStage(_ step: TakeScript.Step) throws -> Stage {
        guard let stage else { throw TakeError.script("\(step.action) only works on web pages for now") }
        return stage
    }

    /// Play the script, or only through scene `lastScene` (1-based) for a preview.
    func play(_ script: TakeScript, through lastScene: Int? = nil) async throws {
        for (i, scene) in script.scenes.enumerated() {
            if let lastScene, i >= lastScene { break }
            onScene?(i, scene.title)
            for (j, step) in scene.steps.enumerated() {
                do {
                    try await perform(step)
                } catch TakeError.target where step.optional == true {
                    continue // optional step whose target didn't show up
                } catch let error as TakeError {
                    throw TakeError.script("Scene \(i + 1) \"\(scene.title)\", step \(j + 1) (\(step.action)): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Steps

    private func perform(_ step: TakeScript.Step) async throws {
        switch step.action {
        case "point":
            try await motion.glide(to: try await point(step), duration: step.duration)

        case "say":
            guard let text = step.text else { throw TakeError.script("say needs text") }
            try await motion.say(text)

        case "newline":
            try requireBubble(step)
            _ = viewModel.handleNewline()
            try await sleep(0.12)

        case "clear":
            try requireBubble(step)
            viewModel.handleClearAll()
            try await sleep(0.12)

        case "pin":
            try requireBubble(step)
            viewModel.pinCurrentPill() // a fresh, empty bubble stays open
            try await sleep(0.2)

        case "hide":
            if viewModel.isActive {
                viewModel.dismiss()
                try await sleep(0.15)
            }

        case "dismiss":
            if viewModel.isActive || !viewModel.pinnedPills.isEmpty {
                viewModel.dismissAll()
                try await sleep(0.2)
            }

        case "circle":
            let r = try await rect(step)
            try await motion.doodle([Shapes.ellipse(around: r, pad: CGFloat(step.pad ?? 16))], durations: [step.duration ?? 0.9])

        case "underline":
            let r = try await rect(step)
            try await motion.doodle([Shapes.underline(r)], durations: [step.duration ?? 0.35])

        case "arrow":
            let tip = try await point(step, defaultAnchor: "left")
            let from = step.from ?? [-170, -90]
            let start = CGPoint(x: tip.x + CGFloat(from[0]), y: tip.y + CGFloat(from[1]))
            try await motion.doodle(Shapes.arrow(from: start, to: tip), durations: [step.duration ?? 0.45, 0.12, 0.12])

        case "scroll":
            try await prepareForScroll()
            if let target = step.target {
                try await scroll(to: target, align: step.align ?? 0.15, duration: step.duration)
            } else if let by = step.by {
                try await scroll(by: by, duration: step.duration)
            } else {
                throw TakeError.script("scroll needs a target or by")
            }

        case "click":
            try await motion.glide(to: try await point(step), duration: step.duration)
            try await sleep(0.08)
            try await requireStage(step).click(at: pos)
            try await sleep(0.1)

        case "type":
            guard let text = step.text else { throw TakeError.script("type needs text") }
            let stage = try requireStage(step)
            try await motion.typeRhythm(text) { try await stage.typeChar($0) }

        case "key":
            try await requireStage(step).key(step.key ?? "")
            try await sleep(0.12)

        case "wait":
            try await sleep(step.seconds ?? 1)

        default:
            throw TakeError.script("Unknown action \"\(step.action)\"")
        }
    }

    private func requireBubble(_ step: TakeScript.Step) throws {
        guard viewModel.isActive else { throw TakeError.script("\(step.action) needs the bubble on; add a say first") }
    }

    /// Doodles and pins are pinned to the screen, not the page, so scrolling would leave them over
    /// the wrong content. Doodles are cleared automatically; pins are deliberate, so that's an error.
    private func prepareForScroll() async throws {
        if !viewModel.pinnedPills.isEmpty {
            throw TakeError.script("Pins stay fixed on screen while the page scrolls; dismiss them first")
        }
        if !viewModel.strokes.isEmpty {
            viewModel.clearStrokesAnimated()
            try await sleep(0.25)
        }
    }

    // MARK: Targets

    private func rect(_ step: TakeScript.Step) async throws -> CGRect {
        if let e = step.element {
            guard let found = AXFinder.find(app: e.app, title: e.title, role: e.role, window: e.window, index: e.index ?? 0) else {
                throw TakeError.target("\"\(e.title)\" in \(e.app)")
            }
            return found.frame
        }
        guard let t = step.target else { throw TakeError.script("\(step.action) needs a target") }
        return try await requireStage(step).rect(t)
    }

    private func point(_ step: TakeScript.Step, defaultAnchor: String = "center") async throws -> CGPoint {
        GhostMotion.anchor(try await rect(step), step.anchor, offset: step.offset, defaultAnchor: defaultAnchor)
    }

    // MARK: Scrolling

    private func scroll(to target: String, align: Double, duration: Double?) async throws {
        guard let stage else { throw TakeError.script("scroll only works on web pages for now") }
        guard let r = try await stage.viewportRect(target) else { throw TakeError.target(target) }
        let y = try await stage.scrollY()
        let desired = min(max(0, y + Double(r.minY) - align * Double(stage.viewport.height)), try await stage.maxScrollY())
        try await scroll(by: desired - y, duration: duration)
    }

    /// Eased wheel scrolling at the pointer. The first scroll calibrates direction, and every scroll
    /// corrects for any shortfall.
    private func scroll(by pixels: Double, duration: Double?) async throws {
        guard abs(pixels) > 2 else { return }
        guard let stage else { throw TakeError.script("scroll only works on web pages for now") }
        if !stage.screenRect.insetBy(dx: 40, dy: 40).contains(pos) {
            try await motion.glide(to: stage.vp(stage.viewport.width * 0.7, stage.viewport.height * 0.5))
        }
        let before = try await stage.scrollY()
        let T = duration ?? min(1.3, max(0.5, abs(pixels) / 1500))
        try await wheel(pixels, duration: T)
        try await sleep(0.12)
        var moved = try await stage.scrollY() - before

        if !scrollCalibrated {
            if abs(moved) <= 3 || (moved > 0) != (pixels > 0) {
                scrollSign = -scrollSign
                try await wheel(pixels - moved, duration: T)
                try await sleep(0.12)
                moved = try await stage.scrollY() - before
                if abs(moved) <= 3 { throw TakeError.devTools("the page didn't scroll") }
            }
            scrollCalibrated = true
        }

        let short = pixels - moved
        if abs(short) > 24 {
            try await wheel(short, duration: 0.25)
            try await sleep(0.1)
        }
    }

    private func wheel(_ pixels: Double, duration: Double) async throws {
        var sent = 0.0
        try await motion.animate { t in
            let u = min(1, t / duration)
            let want = (pixels * GhostMotion.easeInOutCubic(u)).rounded()
            let delta = (want - sent) * self.scrollSign
            sent = want
            if delta != 0 { try await self.stage?.mouse("mouseWheel", at: self.pos, deltaY: delta) }
            return u < 1
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Hand-drawn-looking doodle shapes, in screen coordinates.
enum Shapes {
    /// Loose ellipse around a rect, starting lower-left and overshooting its start a little.
    static func ellipse(around r: CGRect, pad: CGFloat = 18) -> [CGPoint] {
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = Double(r.width / 2 + pad), ry = Double(r.height / 2 + pad * 0.9)
        let tilt = -0.025, phase = Double.random(in: 0...6)
        let start = Double.pi * 0.86, sweep = 2 * Double.pi * 1.1
        return (0...110).map { i in
            let u = Double(i) / 110
            let th = start + sweep * u
            let wobble = 1 + 0.025 * sin(2 * th + phase) + (u > 0.88 ? (u - 0.88) * 0.5 : 0)
            let x = rx * cos(th) * wobble, y = ry * sin(th) * wobble
            return CGPoint(x: c.x + CGFloat(x * cos(tilt) - y * sin(tilt)), y: c.y + CGFloat(x * sin(tilt) + y * cos(tilt)))
        }
    }

    /// Slightly wavy underline beneath a rect.
    static func underline(_ r: CGRect, gap: CGFloat = 6) -> [CGPoint] {
        (0...30).map { i in
            let u = CGFloat(i) / 30
            return CGPoint(x: r.minX - 4 + (r.width + 10) * u, y: r.maxY + gap - 3 * u + 2 * sin(u * .pi * 3))
        }
    }

    /// Curved arrow from → to, as three strokes (shaft + two head lines).
    static func arrow(from a: CGPoint, to b: CGPoint, bend: CGFloat = 0.18) -> [[CGPoint]] {
        let dx = b.x - a.x, dy = b.y - a.y
        let ctrl = CGPoint(x: a.x + dx / 2 - dy * bend, y: a.y + dy / 2 + dx * bend)
        let shaft = (0...40).map { i in GhostMotion.quad(a, ctrl, b, CGFloat(i) / 40) }
        let back = atan2(b.y - ctrl.y, b.x - ctrl.x) + .pi
        let head: (CGFloat) -> [CGPoint] = { off in
            let e = CGPoint(x: b.x + 28 * cos(back + off), y: b.y + 28 * sin(back + off))
            return [e, CGPoint(x: (e.x + b.x) / 2, y: (e.y + b.y) / 2), b]
        }
        return [shaft, head(0.5), head(-0.5)]
    }
}
