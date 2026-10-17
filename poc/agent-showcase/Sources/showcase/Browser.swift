import AppKit
import CoreGraphics
import Foundation

/// A dedicated Chrome window (own profile, app mode, debug port) sized so the page viewport is
/// exactly `viewport`, centered on the main display. Works on any site: targets are CSS
/// selectors or `text:` matches, looked up live over the DevTools protocol.
final class Browser {
    let port: Int
    let url: String
    let viewport: CGSize
    let profileDir: URL
    private(set) var page: CDP!
    private var browser: CDP!
    private var targetId = ""
    private(set) var origin = CGPoint.zero // viewport's top-left on screen

    init(port: Int, url: String, viewport: CGSize, profileDir: URL) {
        self.port = port
        self.url = url
        self.viewport = viewport
        self.profileDir = profileDir
    }

    private func endpoint(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func launchOrAttach() throws {
        if CDP.getJSON(endpoint("/json/version")) == nil {
            log("launching Chrome on port \(port)")
            let chrome = Process()
            chrome.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
            chrome.arguments = [
                "--user-data-dir=\(profileDir.path)",
                "--remote-debugging-port=\(port)",
                "--app=\(url)",
                "--no-first-run",
                "--no-default-browser-check",
                "--hide-crash-restore-bubble",
                "--disable-features=Translate,MediaRouter",
                "--window-size=\(Int(viewport.width)),\(Int(viewport.height) + 40)",
            ]
            chrome.standardOutput = FileHandle.nullDevice
            chrome.standardError = FileHandle.nullDevice
            try chrome.run()
            let deadline = Date().addingTimeInterval(20)
            while CDP.getJSON(endpoint("/json/version")) == nil {
                if Date() > deadline { throw DriverError.cdp("Chrome didn't open its debug port") }
                Thread.sleep(forTimeInterval: 0.25)
            }
        } else {
            log("attaching to Chrome already on port \(port)")
        }

        guard let version = CDP.getJSON(endpoint("/json/version")) as? [String: Any],
              let bws = version["webSocketDebuggerUrl"] as? String, let bURL = URL(string: bws) else {
            throw DriverError.cdp("no browser websocket")
        }
        var pageInfo: [String: Any]?
        let deadline = Date().addingTimeInterval(10)
        while pageInfo == nil {
            let list = CDP.getJSON(endpoint("/json/list")) as? [[String: Any]] ?? []
            pageInfo = list.first { ($0["type"] as? String) == "page" }
            if pageInfo == nil {
                if Date() > deadline { throw DriverError.cdp("no page target") }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard let pws = pageInfo?["webSocketDebuggerUrl"] as? String, let pURL = URL(string: pws) else {
            throw DriverError.cdp("page has no websocket (is DevTools open on it?)")
        }
        targetId = pageInfo?["id"] as? String ?? ""
        browser = CDP(url: bURL)
        page = CDP(url: pURL)
    }

    /// Fresh load of the script's URL, scrolled to the top.
    func load() throws {
        try page.call("Page.navigate", ["url": url])
        Thread.sleep(forTimeInterval: 0.4)
        let deadline = Date().addingTimeInterval(20)
        while true {
            if let ok = try? page.eval("document.readyState === 'complete' && document.fonts.status === 'loaded'") as? Bool, ok { break }
            if Date() > deadline { throw DriverError.cdp("page didn't finish loading") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try page.eval("window.scrollTo(0, 0); true")
        Thread.sleep(forTimeInterval: 0.8) // entry animations
    }

    /// Resize until innerWidth × innerHeight is exactly the viewport, centered on the main display.
    func fitWindow() throws {
        let win = try browser.call("Browser.getWindowForTarget", ["targetId": targetId])
        guard let windowId = win["windowId"] as? Int else { throw DriverError.cdp("no window id") }
        try browser.call("Browser.setWindowBounds", ["windowId": windowId, "bounds": ["windowState": "normal"]])
        let screen = CGDisplayBounds(CGMainDisplayID())
        for _ in 0..<4 {
            let info = try screenInfo()
            let chromeW = info["outerWidth"]! - info["innerWidth"]!
            let chromeH = info["outerHeight"]! - info["innerHeight"]!
            let w = viewport.width + chromeW
            let h = viewport.height + chromeH
            let left = screen.midX - w / 2
            let top = max(screen.minY + 30, screen.midY - h / 2)
            try browser.call("Browser.setWindowBounds", ["windowId": windowId, "bounds": [
                "left": Int(left), "top": Int(top), "width": Int(w), "height": Int(h),
            ]])
            Thread.sleep(forTimeInterval: 0.35)
            let after = try screenInfo()
            if after["innerWidth"]! == viewport.width && after["innerHeight"]! == viewport.height { break }
        }
        let i = try screenInfo()
        guard i["innerWidth"]! == viewport.width && i["innerHeight"]! == viewport.height else {
            throw DriverError.cdp("couldn't size viewport to \(viewport) (got \(i["innerWidth"]!)×\(i["innerHeight"]!)); is the display big enough?")
        }
        origin = CGPoint(
            x: i["screenX"]! + (i["outerWidth"]! - i["innerWidth"]!) / 2,
            y: i["screenY"]! + (i["outerHeight"]! - i["innerHeight"]!)
        )
        log("viewport \(Int(viewport.width))×\(Int(viewport.height)) at screen (\(Int(origin.x)), \(Int(origin.y)))")
    }

    private func screenInfo() throws -> [String: CGFloat] {
        let js = "({screenX, screenY, outerWidth, outerHeight, innerWidth, innerHeight})"
        guard let d = try page.eval(js) as? [String: Any] else { throw DriverError.cdp("screenInfo failed") }
        return d.compactMapValues { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
    }

    var screenRect: CGRect { CGRect(origin: origin, size: viewport) }

    /// Viewport point → screen point.
    func vp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }

    // MARK: Targets

    /// `#id` / any CSS selector, or `text:Some words` for the innermost visible element containing them.
    private static let findJS = """
    (t) => {
      let el = null;
      if (t.startsWith('text:')) {
        const q = t.slice(5).trim().toLowerCase();
        const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
          return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
        const hits = [...document.querySelectorAll('body *')]
          .filter((e) => (e.textContent || '').toLowerCase().includes(q) && visible(e));
        const set = new Set(hits);
        el = hits.find((e) => ![...e.children].some((c) => set.has(c))) || null;
      } else {
        el = document.querySelector(t);
      }
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.left, y: r.top, width: r.width, height: r.height };
    }
    """

    /// Viewport-relative rect of a target, or nil if it isn't on the page.
    func viewportRect(_ target: String) throws -> CGRect? {
        let arg = String(decoding: try JSONSerialization.data(withJSONObject: [target]), as: UTF8.self)
        guard let r = try page.eval("(\(Self.findJS))(...\(arg))") as? [String: Any],
              let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
              let w = (r["width"] as? NSNumber)?.doubleValue, let h = (r["height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Screen rect of a target once it has stopped moving (scroll-reveal animations settle first).
    func rect(_ target: String) throws -> CGRect {
        var last: CGRect?
        let deadline = Date().addingTimeInterval(1.6)
        while true {
            guard let r = try viewportRect(target) else { throw DriverError.target(target) }
            let settled = last.map { abs($0.minX - r.minX) < 0.5 && abs($0.minY - r.minY) < 0.5 } ?? false
            if settled || Date() > deadline { return r.offsetBy(dx: origin.x, dy: origin.y) }
            last = r
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    func scrollY() throws -> Double {
        (try page.eval("window.scrollY") as? NSNumber)?.doubleValue ?? 0
    }

    func maxScrollY() throws -> Double {
        (try page.eval("document.documentElement.scrollHeight - window.innerHeight") as? NSNumber)?.doubleValue ?? 0
    }

    /// Instant scroll (dry runs only; real takes scroll with the wheel).
    func jumpScroll(to y: Double) throws { try page.eval("window.scrollTo(0, \(y)); true") }

    /// Bring this Chrome instance to the front.
    func activate() {
        let pids = shell("/usr/sbin/lsof", ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])
            .split(separator: "\n").compactMap { pid_t($0) }
        for pid in pids {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}
