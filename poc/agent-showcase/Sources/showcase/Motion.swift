import CoreGraphics
import Foundation

/// Screen Studio–style cursor motion: the cursor chases a guide point that travels along a gently
/// curved path, through an under-damped spring, so it accelerates, slightly overshoots and settles.
final class Motion {
    let input: Input
    static let fps = 120.0
    private let dt = 1.0 / fps

    // Spring: ω ≈ 21 rad/s, critically damped (ζ 1) → smooth arrival, no overshoot.
    var stiffness = 440.0
    var damping = 2 * 1.0 * sqrt(440.0)

    init(input: Input) { self.input = input }

    /// Run `frame(t)` at 120 Hz on a fixed clock until it returns false.
    private func animate(_ frame: (Double) throws -> Bool) throws {
        let start = Date()
        var i = 0
        while true {
            let t = Double(i) * dt
            if try !frame(t) { break }
            i += 1
            if !input.dry {
                let wait = start.addingTimeInterval(Double(i) * dt).timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
    }

    /// Glide to `target`. Duration scales with distance unless given.
    func glide(to target: CGPoint, duration: Double? = nil, arc: Double? = nil) throws {
        let start = input.pos
        let dx = target.x - start.x
        let dy = target.y - start.y
        let dist = hypot(dx, dy)
        guard dist > 1 else { return }
        let T = duration ?? min(1.1, max(0.45, 0.3 + Double(dist) / 1800))
        let bend = arc ?? (Double.random(in: 0.03...0.07) * (Bool.random() ? 1 : -1))
        // Control point pushed sideways from the midpoint → a soft arc instead of a ruler line.
        let ctrl = CGPoint(x: start.x + dx / 2 - dy * bend, y: start.y + dy / 2 + dx * bend)

        var p = start
        var v = CGVector.zero
        try animate { t in
            let u = min(1, t / T)
            let s = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 // easeInOutCubic
            let guide = quad(start, ctrl, target, CGFloat(s))
            let ax: Double = stiffness * Double(guide.x - p.x) - damping * Double(v.dx)
            let ay: Double = stiffness * Double(guide.y - p.y) - damping * Double(v.dy)
            v.dx += CGFloat(ax * dt)
            v.dy += CGFloat(ay * dt)
            p.x += v.dx * CGFloat(dt)
            p.y += v.dy * CGFloat(dt)
            try input.move(p)
            let offBy: CGFloat = hypot(target.x - p.x, target.y - p.y)
            let speed: CGFloat = hypot(v.dx, v.dy)
            let settled = offBy < 0.6 && speed < 6
            return !(u >= 1 && settled) && t < T + 0.7
        }
        try input.move(target)
    }

    /// Follow a drawn path (doodles) at an eased pace. Emits drags when the button is down.
    func trace(_ points: [CGPoint], duration: Double) throws {
        guard points.count > 1 else { return }
        var lengths = [0.0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)))
        }
        let total = lengths.last!
        var seg = 1
        try animate { t in
            let u = min(1, t / duration)
            let s = -(cos(Double.pi * u) - 1) / 2 // easeInOutSine: pen speeds up then slows
            let d = s * total
            while seg < points.count - 1 && lengths[seg] < d { seg += 1 }
            let span = max(0.0001, lengths[seg] - lengths[seg - 1])
            let k = CGFloat((d - lengths[seg - 1]) / span)
            try input.move(lerp(points[seg - 1], points[seg], k))
            return u < 1
        }
    }

    /// Eased wheel scroll by `pixels` (positive = page down), spread over `duration`.
    func scroll(by pixels: Double, duration: Double, sign: Double = 1) throws {
        var sent = 0.0
        try animate { t in
            let u = min(1, t / duration)
            let s = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 // easeInOutCubic
            let want = (pixels * s).rounded()
            try input.checkAbort()
            input.scroll(Int32((want - sent) * sign))
            sent = want
            return u < 1
        }
    }

    /// Quick side-to-side shake around the current point (Pubbles' wiggle-to-activate).
    func wiggle(amplitude: Double = 80, frequency: Double = 9.5, duration: Double = 0.6) throws {
        let c = input.pos
        try animate { t in
            let env = sin(Double.pi * min(1, t / duration)) // ramp in and out
            let x = Double(c.x) + amplitude * (0.35 + 0.65 * env) * sin(2 * Double.pi * frequency * t)
            let y = Double(c.y) + 6 * sin(2 * Double.pi * frequency * 0.5 * t)
            try input.move(CGPoint(x: x, y: y))
            return t < duration
        }
        try glide(to: c, duration: 0.18, arc: 0)
    }

    /// Stay roughly still for a while, drifting a few pixels so the cursor doesn't look frozen.
    func hold(_ seconds: Double, drift: CGFloat = 5) throws {
        let start = input.pos
        let to = CGPoint(x: start.x + CGFloat.random(in: -drift...drift), y: start.y + CGFloat.random(in: -drift...drift))
        try animate { t in
            let u = min(1, t / seconds)
            let s = CGFloat(-(cos(Double.pi * u) - 1) / 2)
            try input.move(CGPoint(x: start.x + (to.x - start.x) * s, y: start.y + (to.y - start.y) * s))
            return u < 1
        }
    }

    /// Human-ish typing: quick letters, small pauses on spaces and punctuation, slight cursor drift.
    /// `key` delivers each character; by default it's a real keystroke.
    func type(_ text: String, cps: Double = 22, drift: CGVector = CGVector(dx: 6, dy: 2), key: ((Character) throws -> Void)? = nil) throws {
        let start = input.pos
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            try input.checkAbort()
            if let key { try key(ch) } else { input.typeChar(ch) }
            var delay = 1 / cps * Double.random(in: 0.7...1.3)
            if ch == " " { delay *= 1.4 }
            if ".,?!".contains(ch) { delay *= 3 }
            let u = CGFloat(i + 1) / CGFloat(chars.count)
            try input.move(CGPoint(x: start.x + drift.dx * u, y: start.y + drift.dy * u))
            input.sleep(delay)
        }
    }

    /// Dictation-style typing: words land a few at a time, like live speech-to-text.
    func babble(_ text: String) throws {
        let words = text.split(separator: " ").map(String.init)
        var i = 0
        let start = input.pos
        while i < words.count {
            let n = min(words.count - i, Int.random(in: 1...3))
            let chunk = words[i..<(i + n)].joined(separator: " ") + (i + n < words.count ? " " : "")
            for ch in chunk {
                input.typeChar(ch)
                input.sleep(0.006)
            }
            i += n
            let u = CGFloat(i) / CGFloat(words.count)
            try input.move(CGPoint(x: start.x + 8 * u, y: start.y + 2 * u))
            input.sleep(Double.random(in: 0.16...0.3))
        }
    }

    /// Hold ⌘ and draw each stroke (Pubbles' hold-to-doodle).
    /// Draw each stroke with left-drags. With `holdCmd` it's Pubbles' hold-to-doodle; without, the
    /// caller has already switched drawing on (e.g. through the agent control channel).
    func doodle(_ strokes: [[CGPoint]], durations: [Double], holdCmd: Bool = true) throws {
        if holdCmd {
            input.setCmd(true)
            input.sleep(0.09)
        }
        defer { input.releaseAll() }
        for (i, stroke) in strokes.enumerated() where stroke.count > 1 {
            try glide(to: stroke[0], duration: i == 0 ? nil : 0.22)
            input.leftDown()
            input.sleep(0.02)
            try trace(stroke, duration: durations[min(i, durations.count - 1)])
            input.leftUp()
            input.sleep(0.05)
        }
    }
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint {
    let x: CGFloat = a.x + (b.x - a.x) * k
    let y: CGFloat = a.y + (b.y - a.y) * k
    return CGPoint(x: x, y: y)
}

/// Point on a quadratic Bézier.
func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ s: CGFloat) -> CGPoint {
    let k: CGFloat = 1 - s
    let x: CGFloat = k * k * a.x + 2 * k * s * c.x + s * s * b.x
    let y: CGFloat = k * k * a.y + 2 * k * s * c.y + s * s * b.y
    return CGPoint(x: x, y: y)
}

/// Hand-drawn-looking shapes for doodles, in screen coordinates.
enum Shapes {
    /// Loose ellipse around a rect, starting lower-left and overshooting its start a little.
    static func ellipse(around r: CGRect, pad: CGFloat = 18) -> [CGPoint] {
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2 + pad
        let ry = r.height / 2 + pad * 0.9
        let tilt = -0.025
        let phase = Double.random(in: 0...6)
        let start = Double.pi * 0.86
        let sweep = 2 * Double.pi * 1.1
        return (0...110).map { i in
            let u = Double(i) / 110
            let th = start + sweep * u
            let wobble = 1 + 0.025 * sin(2 * th + phase) + (u > 0.88 ? (u - 0.88) * 0.5 : 0)
            let x = Double(rx) * cos(th) * wobble
            let y = Double(ry) * sin(th) * wobble
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
        let dx = b.x - a.x
        let dy = b.y - a.y
        let ctrl = CGPoint(x: a.x + dx / 2 - dy * bend, y: a.y + dy / 2 + dx * bend)
        let shaft = (0...40).map { i in quad(a, ctrl, b, CGFloat(i) / 40) }
        let back = atan2(b.y - ctrl.y, b.x - ctrl.x) + .pi
        let head: (CGFloat) -> [CGPoint] = { off in
            let e = CGPoint(x: b.x + 28 * cos(back + off), y: b.y + 28 * sin(back + off))
            return [e, CGPoint(x: (e.x + b.x) / 2, y: (e.y + b.y) / 2), b]
        }
        return [shaft, head(0.5), head(-0.5)]
    }

    /// A quick sketch of a grass tuft: one zig-zag stroke of blades.
    static func tuft(base c: CGPoint, width: CGFloat = 120) -> [CGPoint] {
        let heights: [CGFloat] = [44, 70, 52, 82, 58, 40]
        var pts: [CGPoint] = []
        for (i, h) in heights.enumerated() {
            let x0 = c.x - width / 2 + width * CGFloat(i) / CGFloat(heights.count)
            let step = width / CGFloat(heights.count)
            pts.append(CGPoint(x: x0, y: c.y))
            pts.append(CGPoint(x: x0 + step * 0.45 + CGFloat.random(in: -4...4), y: c.y - h))
        }
        pts.append(CGPoint(x: c.x + width / 2, y: c.y))
        return pts
    }
}
