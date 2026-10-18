import AppKit

/// How the ghost pointer moves, draws and types: spring-eased glides, eased doodle tracing and a
/// human typing rhythm. Shared by scripted takes (TakePlayer) and live mode (LivePresenter).
/// Cancelling the surrounding task stops it at the next frame.
@MainActor
final class GhostMotion {
    let viewModel: SubtitleViewModel
    /// The pointer never leaves this rect (the stage window during a take).
    var bounds: CGRect?
    /// Called (at most 60 times a second) as the pointer moves, e.g. to hover the page under it.
    var onHover: ((CGPoint) -> Void)?

    private(set) var pos: CGPoint
    private var penDown = false
    private var lastHover = Date.distantPast

    static let fps = 120.0
    let dt = 1.0 / GhostMotion.fps
    // Spring: ω ≈ 21 rad/s, critically damped → smooth arrival, no overshoot.
    private let stiffness = 440.0
    private let damping = 2 * sqrt(440.0)

    init(viewModel: SubtitleViewModel, start: CGPoint, bounds: CGRect? = nil) {
        self.viewModel = viewModel
        self.bounds = bounds
        self.pos = start
        move(start)
    }

    // MARK: Bubble

    func showBubble() async throws {
        guard !viewModel.isActive else { return }
        viewModel.activate()
        try await sleep(0.18)
    }

    /// Bubble on, then type `text` into it; "\n" starts a new line.
    func say(_ text: String) async throws {
        try await showBubble()
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 {
                _ = viewModel.handleNewline()
                try await sleep(0.12)
            }
            try await typeRhythm(line) { self.viewModel.handleCharacter(String($0)) }
        }
    }

    /// Draw strokes as doodles. They need an active bubble (strokes render with it).
    func doodle(_ strokes: [[CGPoint]], durations: [Double]) async throws {
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

    // MARK: Motion

    func move(_ point: CGPoint) {
        var p = point
        if let b = bounds?.insetBy(dx: 2, dy: 2) {
            p = CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
        }
        pos = p
        if penDown {
            viewModel.ghostStrokeTo(p)
            return
        }
        viewModel.moveGhost(to: p)
        if let onHover, Date().timeIntervalSince(lastHover) > 1.0 / 60 {
            lastHover = Date()
            onHover(p)
        }
    }

    /// Run `frame(t)` on a fixed clock until it returns false. Cancellation stops it.
    func animate(_ frame: (Double) async throws -> Bool) async throws {
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

    func sleep(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// Glide along a gentle arc through a critically damped spring. Duration scales with distance.
    func glide(to target: CGPoint, duration: Double? = nil) async throws {
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
    func trace(_ points: [CGPoint], duration: Double) async throws {
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
    func typeRhythm(_ text: String, cps: Double = 22, _ emit: (Character) async throws -> Void) async throws {
        for ch in text {
            try await emit(ch)
            var delay = 1 / cps * Double.random(in: 0.7...1.3)
            if ch == " " { delay *= 1.4 }
            if ".,?!".contains(ch) { delay *= 3 }
            try await sleep(delay)
        }
    }

    // MARK: Geometry

    /// A point next to a rect: center, or just left/right/above/below it, plus an offset.
    static func anchor(_ r: CGRect, _ anchor: String?, offset: [Double]?, defaultAnchor: String = "center") -> CGPoint {
        var p: CGPoint
        switch anchor ?? defaultAnchor {
        case "left": p = CGPoint(x: r.minX - 14, y: r.midY)
        case "right": p = CGPoint(x: r.maxX + 14, y: r.midY)
        case "above": p = CGPoint(x: r.midX, y: r.minY - 24)
        case "below": p = CGPoint(x: r.midX, y: r.maxY + 10)
        default: p = CGPoint(x: r.midX, y: r.midY)
        }
        if let o = offset, o.count == 2 {
            p.x += CGFloat(o[0])
            p.y += CGFloat(o[1])
        }
        return p
    }

    static func easeInOutCubic(_ u: Double) -> Double {
        u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    nonisolated static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ s: CGFloat) -> CGPoint {
        let k = 1 - s
        return CGPoint(x: k * k * a.x + 2 * k * s * c.x + s * s * b.x,
                       y: k * k * a.y + 2 * k * s * c.y + s * s * b.y)
    }
}
