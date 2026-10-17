import CoreGraphics
import Foundation

/// A showcase script: what an agent writes after reviewing a page, then hands to the player.
struct Script: Decodable {
    let url: String
    var viewport: [Double]?
    /// Viewport point clicked once before the take to give the page keyboard focus.
    var focusAt: [Double]?
    let steps: [Step]
}

struct Step: Decodable {
    let action: String
    var target: String?   // CSS selector, or "text:Some words"
    var anchor: String?   // center | left | right | above | below
    var offset: [Double]? // [dx, dy] added to the anchor point
    var text: String?
    var key: String?
    var by: Double?       // scroll: pixels, positive = down
    var align: Double?    // scroll: where the target's top lands, as a fraction of viewport height
    var from: [Double]?   // arrow: start point relative to the arrow tip
    var pad: Double?
    var duration: Double?
    var seconds: Double?

    enum CodingKeys: String, CodingKey {
        case action = "do"
        case target, anchor, offset, text, key, by, align, from, pad, duration, seconds
    }

    var summary: String {
        [action, target, text.map { "\"\($0)\"" }, key, by.map { "\(Int($0))px" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// Plays a script with real input: the real cursor moves, Pubbles is driven through its own
/// hotkeys, and the page is scrolled with real wheel events and clicked with real clicks.
///
/// The one rule it enforces: while the bubble is on, Pubbles owns the keyboard, so typing or
/// pressing keys *into the page* needs a `hide` first. Clicks and scrolling pass through anyway.
///
/// Pubbles itself is driven through its agent control channel (see `Pubbles`), not hotkeys.
final class Player {
    let input: Input
    let motion: Motion
    let browser: Browser
    let pubbles: Pubbles

    private var scrollSign = 1.0
    private var scrollCalibrated = false

    private var bubbleOn: Bool { pubbles.state.active }

    init(input: Input, motion: Motion, browser: Browser, pubbles: Pubbles) {
        self.input = input
        self.motion = motion
        self.browser = browser
        self.pubbles = pubbles
    }

    func run(_ steps: [Step]) throws {
        for (i, step) in steps.enumerated() {
            log("▸ \(i + 1)/\(steps.count) \(step.summary)")
            do {
                try perform(step)
            } catch let error as DriverError {
                throw DriverError.script("step \(i + 1) (\(step.action)): \(error)")
            }
        }
    }

    private func perform(_ step: Step) throws {
        switch step.action {
        case "point":
            try motion.glide(to: try point(step), duration: step.duration)

        case "say":
            guard let text = step.text else { throw DriverError.script("say needs text") }
            try showBubble()
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if i > 0 { try pubbles.send("newline"); input.sleep(0.12) }
                try motion.type(line) { try self.pubbles.send("type", ["text": String($0)]) }
            }

        case "newline":
            try requireBubble(step)
            try pubbles.send("newline")
            input.sleep(0.12)

        case "clear":
            try requireBubble(step)
            try pubbles.send("clear")
            input.sleep(0.12)

        case "pin":
            try requireBubble(step)
            try pubbles.send("pin") // Pubbles keeps a fresh, empty bubble open after pinning
            input.sleep(0.2)

        case "hide":
            if bubbleOn {
                try pubbles.send("hide")
                input.sleep(0.15)
            }

        case "dismiss":
            if bubbleOn || pubbles.state.pins > 0 {
                try pubbles.send("dismissAll")
                input.sleep(0.2)
            }

        case "circle":
            let r = try rect(step)
            try doodle([Shapes.ellipse(around: r, pad: CGFloat(step.pad ?? 16))], durations: [step.duration ?? 0.9])

        case "underline":
            let r = try rect(step)
            try doodle([Shapes.underline(r)], durations: [step.duration ?? 0.35])

        case "arrow":
            let tip = try point(step, defaultAnchor: "left")
            let from = step.from ?? [-170, -90]
            let start = CGPoint(x: tip.x + CGFloat(from[0]), y: tip.y + CGFloat(from[1]))
            try doodle(Shapes.arrow(from: start, to: tip), durations: [step.duration ?? 0.45, 0.12, 0.12])

        case "scroll":
            if let target = step.target {
                try scroll(to: target, align: step.align ?? 0.15, duration: step.duration)
            } else if let by = step.by {
                try scroll(by: by, duration: step.duration)
            } else {
                throw DriverError.script("scroll needs a target or by")
            }

        case "click":
            try motion.glide(to: try point(step), duration: step.duration)
            input.sleep(0.08)
            input.click()
            input.sleep(0.1)
            if pubbles.clickToDismiss { try pubbles.send("state") }

        case "type":
            guard let text = step.text else { throw DriverError.script("type needs text") }
            try requirePageKeyboard(step)
            try motion.type(text)

        case "key":
            guard let name = step.key, let code = Self.keyCodes[name.lowercased()] else {
                throw DriverError.script("unknown key \(step.key ?? "nil"); known: \(Self.keyCodes.keys.sorted().joined(separator: ", "))")
            }
            try requirePageKeyboard(step)
            if code == Keys.escape && pubbles.state.pins > 0 {
                throw DriverError.script("pins are on screen, so Pubbles would take this Esc; dismiss them first")
            }
            input.press(code)
            input.sleep(0.12)

        case "wait":
            try motion.hold(step.seconds ?? 1)

        default:
            throw DriverError.script("unknown action \"\(step.action)\"")
        }
    }

    // MARK: Pubbles

    private func showBubble() throws {
        guard !bubbleOn else { return }
        try pubbles.send("show")
        input.sleep(0.18)
    }

    /// Doodles need an active bubble (that's when Pubbles' overlay accepts drags as strokes).
    private func doodle(_ strokes: [[CGPoint]], durations: [Double]) throws {
        try showBubble()
        try pubbles.send("draw", ["on": true])
        input.sleep(0.06) // let the overlay start taking mouse events
        defer { _ = try? pubbles.send("draw", ["on": false]) }
        try motion.doodle(strokes, durations: durations, holdCmd: false)
    }

    // MARK: Rules

    private func requireBubble(_ step: Step) throws {
        guard bubbleOn else { throw DriverError.script("\(step.action) needs the bubble on; add a say first") }
    }

    private func requirePageKeyboard(_ step: Step) throws {
        guard !bubbleOn else {
            throw DriverError.script("the bubble is on, so Pubbles would capture this \(step.action); add a hide first")
        }
    }

    // MARK: Targets

    private func rect(_ step: Step) throws -> CGRect {
        guard let t = step.target else { throw DriverError.script("\(step.action) needs a target") }
        return try browser.rect(t)
    }

    private func point(_ step: Step, defaultAnchor: String = "center") throws -> CGPoint {
        let r = try rect(step)
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

    private func scroll(to target: String, align: Double, duration: Double?) throws {
        guard let r = try browser.viewportRect(target) else { throw DriverError.target(target) }
        let y = try browser.scrollY()
        let desired = min(max(0, y + Double(r.minY) - align * Double(browser.viewport.height)), try browser.maxScrollY())
        try scroll(by: desired - y, duration: duration)
    }

    /// Real wheel scrolling with the cursor over the page. The first scroll calibrates direction
    /// (natural scrolling can flip synthetic events), and every scroll corrects for any shortfall.
    private func scroll(by pixels: Double, duration: Double?) throws {
        guard abs(pixels) > 2 else { return }
        let before = try browser.scrollY()
        if input.dry {
            try browser.jumpScroll(to: before + pixels)
            return
        }
        if !browser.screenRect.insetBy(dx: 40, dy: 40).contains(input.pos) {
            try motion.glide(to: browser.vp(browser.viewport.width * 0.7, browser.viewport.height * 0.5))
        }
        let T = duration ?? min(1.3, max(0.5, abs(pixels) / 1500))
        try motion.scroll(by: pixels, duration: T, sign: scrollSign)
        input.sleep(0.12)
        var moved = try browser.scrollY() - before

        if !scrollCalibrated {
            let wrongWay = abs(moved) > 3 && (moved > 0) != (pixels > 0)
            if abs(moved) <= 3 || wrongWay {
                log("flipping wheel direction")
                scrollSign = -scrollSign
                try motion.scroll(by: pixels - moved, duration: T, sign: scrollSign)
                input.sleep(0.12)
                moved = try browser.scrollY() - before
                if abs(moved) <= 3 { throw DriverError.script("wheel events didn't scroll the page; is the cursor over Chrome?") }
            }
            scrollCalibrated = true
        }

        let short = pixels - moved
        if abs(short) > 24 {
            try motion.scroll(by: short, duration: 0.25, sign: scrollSign)
            input.sleep(0.1)
        }
    }

    // MARK: Keys

    static let keyCodes: [String: CGKeyCode] = [
        "escape": Keys.escape, "return": Keys.returnKey, "space": 49, "tab": 48,
        "pagedown": 121, "pageup": 116, "down": Keys.down, "up": Keys.up,
    ]
}
