import AppKit

/// Plays a script on the stage with the ghost pointer: Pubbles draws the pointer, bubbles and
/// doodles itself, and the page gets hover, clicks, wheel and keys over DevTools. The user's real
/// mouse and keyboard are never touched. Cancelling the task stops the take at the next frame.
@MainActor
final class TakePlayer {
    let stage: Stage
    let viewModel: SubtitleViewModel
    /// Called when a scene starts (index, title).
    var onScene: ((Int, String) -> Void)?

    private(set) var pos: CGPoint
    private var penDown = false
    private var lastHover = Date.distantPast
    private var scrollSign = 1.0
    private var scrollCalibrated = false

    private static let fps = 120.0
    private let dt = 1.0 / TakePlayer.fps
    // Spring: ω ≈ 21 rad/s, critically damped → smooth arrival, no overshoot.
    private let stiffness = 440.0
    private let damping = 2 * sqrt(440.0)

    init(stage: Stage, viewModel: SubtitleViewModel, start: CGPoint) {
        self.stage = stage
        self.viewModel = viewModel
        self.pos = start
        viewModel.moveGhost(to: start)
    }

    func play(_ script: TakeScript) async throws {
        for (i, scene) in script.scenes.enumerated() {
            onScene?(i, scene.title)
            for (j, step) in scene.steps.enumerated() {
                do {
                    try await perform(step)
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
            try await glide(to: try await point(step), duration: step.duration)

        case "say":
            guard let text = step.text else { throw TakeError.script("say needs text") }
            try await showBubble()
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if i > 0 {
                    _ = viewModel.handleNewline()
                    try await sleep(0.12)
                }
                try await typeRhythm(line) { self.viewModel.handleCharacter(String($0)) }
            }

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
            try await doodle([Shapes.ellipse(around: r, pad: CGFloat(step.pad ?? 16))], durations: [step.duration ?? 0.9])

        case "underline":
            let r = try await rect(step)
            try await doodle([Shapes.underline(r)], durations: [step.duration ?? 0.35])

        case "arrow":
            let tip = try await point(step, defaultAnchor: "left")
            let from = step.from ?? [-170, -90]
            let start = CGPoint(x: tip.x + CGFloat(from[0]), y: tip.y + CGFloat(from[1]))
            try await doodle(Shapes.arrow(from: start, to: tip), durations: [step.duration ?? 0.45, 0.12, 0.12])

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
            try await glide(to: try await point(step), duration: step.duration)
            try await sleep(0.08)
            try await stage.click(at: pos)
            try await sleep(0.1)

        case "type":
            guard let text = step.text else { throw TakeError.script("type needs text") }
            try await typeRhythm(text) { try await self.stage.typeChar($0) }

        case "key":
            try await stage.key(step.key ?? "")
            try await sleep(0.12)

        case "wait":
            try await sleep(step.seconds ?? 1)

        default:
            throw TakeError.script("Unknown action \"\(step.action)\"")
        }
    }

    private func showBubble() async throws {
        guard !viewModel.isActive else { return }
        viewModel.activate()
        try await sleep(0.18)
    }

    private func requireBubble(_ step: TakeScript.Step) throws {
        guard viewModel.isActive else { throw TakeError.script("\(step.action) needs the bubble on; add a say first") }
    }

    /// Doodles need an active bubble (strokes render with it).
    private func doodle(_ strokes: [[CGPoint]], durations: [Double]) async throws {
        try await showBubble()
        for (i, stroke) in strokes.enumerated() where stroke.count > 1 {
            try await glide(to: stroke[0], duration: i == 0 ? nil : 0.22)
            viewModel.ghostStrokeBegin(at: stroke[0])
            penDown = true
            defer {
                penDown = false
                viewModel.endStroke()
            }
            try await trace(stroke, duration: durations[min(i, durations.count - 1)])
            try await sleep(0.05)
        }
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
        guard let t = step.target else { throw TakeError.script("\(step.action) needs a target") }
        return try await stage.rect(t)
    }

    private func point(_ step: TakeScript.Step, defaultAnchor: String = "center") async throws -> CGPoint {
        let r = try await rect(step)
        var p: CGPoint
        switch step.anchor ?? defaultAnchor {
        case "left": p = CGPoint(x: r.minX - 14, y: r.midY)
        case "right": p = CGPoint(x: r.maxX + 14, y: r.midY)
        case "above": p = CGPoint(x: r.midX, y: r.minY - 24)
        case "below": p = CGPoint(x: r.midX, y: r.maxY + 10)
        default: p = CGPoint(x: r.midX, y: r.midY)
        }
        if let o = step.offset, o.count == 2 {
            p.x += CGFloat(o[0])
            p.y += CGFloat(o[1])
        }
        return p
    }

    // MARK: Scrolling

    private func scroll(to target: String, align: Double, duration: Double?) async throws {
        guard let r = try await stage.viewportRect(target) else { throw TakeError.target(target) }
        let y = try await stage.scrollY()
        let desired = min(max(0, y + Double(r.minY) - align * Double(stage.viewport.height)), try await stage.maxScrollY())
        try await scroll(by: desired - y, duration: duration)
    }

    /// Eased wheel scrolling at the pointer. The first scroll calibrates direction, and every scroll
    /// corrects for any shortfall.
    private func scroll(by pixels: Double, duration: Double?) async throws {
        guard abs(pixels) > 2 else { return }
        if !stage.screenRect.insetBy(dx: 40, dy: 40).contains(pos) {
            try await glide(to: stage.vp(stage.viewport.width * 0.7, stage.viewport.height * 0.5))
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
        try await animate { t in
            let u = min(1, t / duration)
            let want = (pixels * Self.easeInOutCubic(u)).rounded()
            let delta = (want - sent) * self.scrollSign
            sent = want
            if delta != 0 { try await self.stage.mouse("mouseWheel", at: self.pos, deltaY: delta) }
            return u < 1
        }
    }

    // MARK: Motion

    private func move(_ p: CGPoint) {
        pos = p
        if penDown {
            viewModel.ghostStrokeTo(p)
            return
        }
        viewModel.moveGhost(to: p)
        // Hover so the page reacts like a real pointer is there (≤60 Hz is plenty).
        if Date().timeIntervalSince(lastHover) > 1.0 / 60 {
            lastHover = Date()
            Task { try? await self.stage.mouse("mouseMoved", at: p) }
        }
    }

    /// Run `frame(t)` on a fixed clock until it returns false. Cancellation stops it.
    private func animate(_ frame: (Double) async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var i = 0
        while true {
            try Task.checkCancellation()
            if try await !frame(Double(i) * dt) { break }
            i += 1
            try await Task.sleep(until: start.advanced(by: .seconds(Double(i) * dt)), clock: clock)
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// Glide along a gentle arc through a critically damped spring. Duration scales with distance.
    private func glide(to target: CGPoint, duration: Double? = nil) async throws {
        let start = pos
        let dx = target.x - start.x, dy = target.y - start.y
        let dist = hypot(dx, dy)
        guard dist > 1 else { return }
        let T = duration ?? min(1.1, max(0.45, 0.3 + Double(dist) / 1800))
        let bend = Double.random(in: 0.03...0.07) * (Bool.random() ? 1 : -1)
        let ctrl = CGPoint(x: start.x + dx / 2 - dy * bend, y: start.y + dy / 2 + dx * bend)
        var p = start
        var v = CGVector.zero
        try await animate { t in
            let u = min(1, t / T)
            let guide = Self.quad(start, ctrl, target, CGFloat(Self.easeInOutCubic(u)))
            let ax = self.stiffness * Double(guide.x - p.x) - self.damping * Double(v.dx)
            let ay = self.stiffness * Double(guide.y - p.y) - self.damping * Double(v.dy)
            v.dx += CGFloat(ax * self.dt)
            v.dy += CGFloat(ay * self.dt)
            p.x += v.dx * CGFloat(self.dt)
            p.y += v.dy * CGFloat(self.dt)
            self.move(p)
            let settled = hypot(target.x - p.x, target.y - p.y) < 0.6 && hypot(v.dx, v.dy) < 6
            return !(u >= 1 && settled) && t < T + 0.7
        }
        move(target)
    }

    /// Follow a drawn path at an eased pace (the pen speeds up, then slows).
    private func trace(_ points: [CGPoint], duration: Double) async throws {
        var lengths = [0.0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)))
        }
        let total = lengths.last!
        var seg = 1
        try await animate { t in
            let u = min(1, t / duration)
            let d = -(cos(Double.pi * u) - 1) / 2 * total
            while seg < points.count - 1 && lengths[seg] < d { seg += 1 }
            let span = max(0.0001, lengths[seg] - lengths[seg - 1])
            let k = CGFloat((d - lengths[seg - 1]) / span)
            let a = points[seg - 1], b = points[seg]
            self.move(CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k))
            return u < 1
        }
    }

    /// Human-ish typing rhythm: quick letters, small pauses on spaces and punctuation.
    private func typeRhythm(_ text: String, cps: Double = 22, _ emit: (Character) async throws -> Void) async throws {
        for ch in text {
            try await emit(ch)
            var delay = 1 / cps * Double.random(in: 0.7...1.3)
            if ch == " " { delay *= 1.4 }
            if ".,?!".contains(ch) { delay *= 3 }
            try await sleep(delay)
        }
    }

    private static func easeInOutCubic(_ u: Double) -> Double {
        u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    nonisolated fileprivate static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ s: CGFloat) -> CGPoint {
        let k = 1 - s
        return CGPoint(x: k * k * a.x + 2 * k * s * c.x + s * s * b.x,
                       y: k * k * a.y + 2 * k * s * c.y + s * s * b.y)
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
        let shaft = (0...40).map { i in TakePlayer.quad(a, ctrl, b, CGFloat(i) / 40) }
        let back = atan2(b.y - ctrl.y, b.x - ctrl.x) + .pi
        let head: (CGFloat) -> [CGPoint] = { off in
            let e = CGPoint(x: b.x + 28 * cos(back + off), y: b.y + 28 * sin(back + off))
            return [e, CGPoint(x: (e.x + b.x) / 2, y: (e.y + b.y) / 2), b]
        }
        return [shaft, head(0.5), head(-0.5)]
    }
}
