import CoreGraphics
import Foundation

/// Ghost mode: Pubbles draws the pointer (the bubble follows it) and doodles land as strokes in
/// Pubbles directly; the page gets hover, wheel and clicks over DevTools. The real mouse and
/// keyboard stay the user's.
final class Ghost: PointerSink {
    let pubbles: Pubbles
    let browser: Browser
    private var lastHover = Date.distantPast

    init(pubbles: Pubbles, browser: Browser) {
        self.pubbles = pubbles
        self.browser = browser
    }

    private func xy(_ p: CGPoint) -> [String: Any] { ["x": Double(p.x), "y": Double(p.y)] }

    func move(_ p: CGPoint, drawing: Bool) {
        pubbles.post(drawing ? "strokeTo" : "ghost", xy(p))
        // Hover so the page reacts like a real pointer is there (≤60 Hz is plenty).
        if !drawing, Date().timeIntervalSince(lastHover) > 1.0 / 60 {
            try? browser.mouse("mouseMoved", at: p)
            lastHover = Date()
        }
    }

    func penDown(_ p: CGPoint) { _ = try? pubbles.send("strokeBegin", xy(p)) }
    func penUp(_ p: CGPoint) { _ = try? pubbles.send("strokeEnd") }
    func wheel(_ dy: Int32, at p: CGPoint) { try? browser.mouse("mouseWheel", at: p, deltaY: Double(dy)) }
}
