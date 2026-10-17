import AppKit

/// The stage: Pubbles' own Chrome window (separate profile, app mode, DevTools port), sized so the
/// page viewport is exactly the script's viewport and centered on the main display. Agents look at
/// the page and act on it through DevTools, so the user's mouse and keyboard are never touched.
@MainActor
final class Stage {
    static let port = 9335
    static let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private(set) var viewport = CGSize(width: 1440, height: 900)
    private(set) var origin = CGPoint.zero // viewport's top-left on screen (global CG coordinates)
    private(set) var chromePID: pid_t = 0
    private var page: DevTools?
    private var browser: DevTools?
    private var targetID = ""

    private var profileDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pubbles/Stage", isDirectory: true)
    }

    private func endpoint(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }

    var screenRect: CGRect { CGRect(origin: origin, size: viewport) }

    /// Viewport point → screen point.
    func vp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }

    // MARK: Opening

    /// Launch (or reuse) the stage window and load `url` fresh, scrolled to the top.
    ///
    /// For a take, the stage comes to the front and the real window is fitted, since the ghost
    /// pointer and the recording need its true position. For exploring (agents looking around,
    /// validating), the page is just told to lay out at the video size: nothing comes to the front,
    /// and it works even while the window is covered.
    func open(url: String, viewport: CGSize, forTake: Bool = false) async throws {
        self.viewport = viewport
        if await DevTools.getJSON(endpoint("/json/version")) == nil {
            try launchChrome(url: url)
        }
        try await attach()
        if forTake {
            try await requirePage().call("Emulation.clearDeviceMetricsOverride")
            activate()
            try await Task.sleep(for: .milliseconds(300))
            try await fitWindow()
        } else {
            try await requirePage().call("Emulation.setDeviceMetricsOverride", [
                "width": Int(viewport.width), "height": Int(viewport.height), "deviceScaleFactor": 0, "mobile": false,
            ])
        }
        try await load(url)
    }

    private func launchChrome(url: String) throws {
        guard FileManager.default.fileExists(atPath: Self.chromePath) else {
            throw TakeError.setup("The stage needs Google Chrome in /Applications")
        }
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let chrome = Process()
        chrome.executableURL = URL(fileURLWithPath: Self.chromePath)
        chrome.arguments = [
            "--user-data-dir=\(profileDir.path)",
            "--remote-debugging-port=\(Self.port)",
            "--app=\(url)",
            "--no-first-run",
            "--no-default-browser-check",
            "--hide-crash-restore-bubble",
            "--disable-features=Translate,MediaRouter",
            // Keep the page live while other windows cover the stage (agents explore in the background).
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--disable-background-timer-throttling",
            "--window-size=\(Int(viewport.width)),\(Int(viewport.height) + 40)",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()
    }

    private func attach() async throws {
        let deadline = Date().addingTimeInterval(20)
        var version: [String: Any]?
        while version == nil {
            version = await DevTools.getJSON(endpoint("/json/version")) as? [String: Any]
            if version == nil {
                if Date() > deadline { throw TakeError.setup("The stage window didn't start") }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let bws = version?["webSocketDebuggerUrl"] as? String, let bURL = URL(string: bws) else {
            throw TakeError.devTools("no browser websocket")
        }
        var pageInfo: [String: Any]?
        while pageInfo == nil {
            let list = await DevTools.getJSON(endpoint("/json/list")) as? [[String: Any]] ?? []
            pageInfo = list.first { ($0["type"] as? String) == "page" }
            if pageInfo == nil {
                if Date() > deadline { throw TakeError.devTools("no page in the stage window") }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let pws = pageInfo?["webSocketDebuggerUrl"] as? String, let pURL = URL(string: pws) else {
            throw TakeError.devTools("the stage page isn't reachable (is DevTools open on it?)")
        }
        page?.close()
        browser?.close()
        targetID = pageInfo?["id"] as? String ?? ""
        browser = DevTools(url: bURL)
        page = DevTools(url: pURL)
        chromePID = Self.listeningPID(port: Self.port) ?? 0
    }

    private func load(_ url: String) async throws {
        let page = try requirePage()
        try await page.call("Page.navigate", ["url": url])
        try await Task.sleep(for: .milliseconds(400))
        let deadline = Date().addingTimeInterval(20)
        while true {
            if let ok = try? await page.eval("document.readyState === 'complete' && document.fonts.status === 'loaded'") as? Bool, ok { break }
            if Date() > deadline { throw TakeError.devTools("the page didn't finish loading") }
            try await Task.sleep(for: .milliseconds(200))
        }
        try await page.eval("window.scrollTo(0, 0); true")
        try await Task.sleep(for: .milliseconds(800)) // entry animations
    }

    /// Resize until the page viewport is exactly `viewport`, centered on the main display.
    private func fitWindow() async throws {
        guard let browser else { throw TakeError.devTools("not attached") }
        let win = try await browser.call("Browser.getWindowForTarget", ["targetId": targetID])
        guard let windowID = win["windowId"] as? Int else { throw TakeError.devTools("no window id") }
        // Un-minimize first, and give it a moment: a minimized or hidden window reports sizes that
        // would make the maths below shrink it to nothing.
        try await browser.call("Browser.setWindowBounds", ["windowId": windowID, "bounds": ["windowState": "normal"]])
        try await Task.sleep(for: .milliseconds(300))
        let screen = CGDisplayBounds(CGMainDisplayID())
        var info = try await screenInfo()
        for _ in 0..<5 {
            // Window frame around the page; fall back to app-mode defaults if the numbers look wrong.
            var frameW = info.outer.width - info.inner.width
            var frameH = info.outer.height - info.inner.height
            if !(0...120).contains(frameW) { frameW = 0 }
            if !(0...160).contains(frameH) { frameH = 28 }
            let w = viewport.width + frameW
            let h = viewport.height + frameH
            try await browser.call("Browser.setWindowBounds", ["windowId": windowID, "bounds": [
                "left": Int(screen.midX - w / 2), "top": Int(max(screen.minY + 30, screen.midY - h / 2)),
                "width": Int(w), "height": Int(h),
            ]])
            try await Task.sleep(for: .milliseconds(350))
            info = try await screenInfo()
            if info.inner == viewport { break }
        }
        guard info.inner == viewport else {
            throw TakeError.setup("Couldn't fit a \(Int(viewport.width))×\(Int(viewport.height)) stage on this display")
        }
        origin = CGPoint(x: info.screen.x + (info.outer.width - info.inner.width) / 2,
                         y: info.screen.y + (info.outer.height - info.inner.height))
    }

    private func screenInfo() async throws -> (screen: CGPoint, outer: CGSize, inner: CGSize) {
        let js = "[screenX, screenY, outerWidth, outerHeight, innerWidth, innerHeight]"
        guard let v = try await requirePage().eval(js) as? [NSNumber], v.count == 6 else {
            throw TakeError.devTools("couldn't read the window size")
        }
        let n = v.map { CGFloat($0.doubleValue) }
        return (CGPoint(x: n[0], y: n[1]), CGSize(width: n[2], height: n[3]), CGSize(width: n[4], height: n[5]))
    }

    func activate() {
        NSRunningApplication(processIdentifier: chromePID)?.activate()
    }

    private func requirePage() throws -> DevTools {
        guard let page else { throw TakeError.devTools("the stage isn't open") }
        return page
    }

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
      return [r.left, r.top, r.width, r.height];
    }
    """

    /// Viewport-relative rect of a target, or nil if it isn't on the page.
    func viewportRect(_ target: String) async throws -> CGRect? {
        let arg = String(decoding: try JSONSerialization.data(withJSONObject: [target]), as: UTF8.self)
        guard let r = try await requirePage().eval("(\(Self.findJS))(...\(arg))") as? [NSNumber], r.count == 4 else { return nil }
        return CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue)
    }

    /// Screen rect of a target once it has stopped moving (scroll-reveal animations settle first).
    func rect(_ target: String) async throws -> CGRect {
        var last: CGRect?
        let deadline = Date().addingTimeInterval(1.6)
        while true {
            guard let r = try await viewportRect(target) else { throw TakeError.target(target) }
            let settled = last.map { abs($0.minX - r.minX) < 0.5 && abs($0.minY - r.minY) < 0.5 } ?? false
            if settled || Date() > deadline { return r.offsetBy(dx: origin.x, dy: origin.y) }
            last = r
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    func scrollY() async throws -> Double {
        (try await requirePage().eval("window.scrollY") as? NSNumber)?.doubleValue ?? 0
    }

    func maxScrollY() async throws -> Double {
        (try await requirePage().eval("document.documentElement.scrollHeight - window.innerHeight") as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: Exploring (for agents, between takes)

    var isOpen: Bool { page != nil }

    func currentURL() async throws -> String {
        (try await requirePage().eval("location.href") as? String) ?? ""
    }

    /// Instant scroll, for looking around (takes scroll with the wheel).
    func jumpScroll(to y: Double) async throws {
        try await requirePage().eval("window.scrollTo(0, \(y)); true")
        try await Task.sleep(for: .milliseconds(150))
    }

    /// Headings, buttons, links, images and fields with a target an agent can use as-is, their
    /// position on the page, and whether they're in view right now.
    func outline(limit: Int = 150) async throws -> [String: Any] {
        let js = """
        (() => {
          const label = (e) => (e.getAttribute('aria-label') || e.alt || e.innerText || e.value || e.placeholder || '')
            .trim().replace(/\\s+/g, ' ');
          const target = (e) => {
            if (e.id) return '#' + CSS.escape(e.id);
            if (e.tagName === 'IMG' && e.alt) return 'img[alt="' + e.alt.replace(/"/g, '\\\\"') + '"]';
            const t = label(e);
            return t && t.length <= 60 ? 'text:' + t : null;
          };
          const items = [], seen = new Set();
          document.querySelectorAll('h1,h2,h3,h4,button,a[href],img,input,textarea,select,[role=button],video').forEach((e) => {
            const r = e.getBoundingClientRect(), s = getComputedStyle(e);
            if (r.width === 0 || r.height === 0 || s.display === 'none' || s.visibility === 'hidden') return;
            const t = target(e);
            if (!t || seen.has(t)) return;
            seen.add(t);
            items.push({ kind: e.tagName.toLowerCase(), label: label(e).slice(0, 80), target: t,
                         pageY: Math.round(r.top + scrollY), inView: r.bottom > 0 && r.top < innerHeight });
          });
          return { url: location.href, title: document.title, scrollY: Math.round(scrollY),
                   pageHeight: document.documentElement.scrollHeight, viewport: [innerWidth, innerHeight],
                   items: items.slice(0, \(limit)) };
        })()
        """
        return (try await requirePage().eval(js) as? [String: Any]) ?? [:]
    }

    /// JPEG of the page viewport (not Pubbles' overlay), downscaled to `width` px.
    func screenshot(width: CGFloat = 960) async throws -> Data {
        let result = try await requirePage().call("Page.captureScreenshot", ["format": "png"])
        guard let b64 = result["data"] as? String, let png = Data(base64Encoded: b64),
              let image = NSImage(data: png) else { throw TakeError.devTools("screenshot failed") }
        let scale = width / max(1, viewport.width)
        let size = NSSize(width: (viewport.width * scale).rounded(), height: (viewport.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw TakeError.devTools("screenshot failed")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw TakeError.devTools("screenshot failed")
        }
        return jpeg
    }

    // MARK: Page input (straight to the page; the real mouse and keyboard stay the user's)

    /// Mouse event at a screen point; ignored outside the viewport.
    func mouse(_ type: String, at p: CGPoint, button: String = "none", clickCount: Int = 0, deltaY: Double = 0) async throws {
        let x = Double(p.x - origin.x), y = Double(p.y - origin.y)
        guard x >= 0, y >= 0, x < Double(viewport.width), y < Double(viewport.height) else { return }
        var params: [String: Any] = ["type": type, "x": x, "y": y, "button": button, "clickCount": clickCount]
        if type == "mouseWheel" {
            params["deltaX"] = 0
            params["deltaY"] = deltaY
        }
        try await requirePage().call("Input.dispatchMouseEvent", params)
    }

    func click(at p: CGPoint) async throws {
        try await mouse("mouseMoved", at: p)
        try await mouse("mousePressed", at: p, button: "left", clickCount: 1)
        try await Task.sleep(for: .milliseconds(50))
        try await mouse("mouseReleased", at: p, button: "left", clickCount: 1)
    }

    func typeChar(_ ch: Character) async throws {
        let s = String(ch)
        try await requirePage().call("Input.dispatchKeyEvent", ["type": "keyDown", "key": s, "text": s, "unmodifiedText": s])
        try await requirePage().call("Input.dispatchKeyEvent", ["type": "keyUp", "key": s])
    }

    private static let pageKeys: [String: (key: String, code: String, vk: Int, text: String?)] = [
        "escape": ("Escape", "Escape", 27, nil), "return": ("Enter", "Enter", 13, "\r"),
        "space": (" ", "Space", 32, " "), "tab": ("Tab", "Tab", 9, nil),
        "pagedown": ("PageDown", "PageDown", 34, nil), "pageup": ("PageUp", "PageUp", 33, nil),
        "down": ("ArrowDown", "ArrowDown", 40, nil), "up": ("ArrowUp", "ArrowUp", 38, nil),
    ]

    func key(_ name: String) async throws {
        guard let k = Self.pageKeys[name.lowercased()] else {
            throw TakeError.script("Unknown key \"\(name)\"; known: \(Self.pageKeys.keys.sorted().joined(separator: ", "))")
        }
        var down: [String: Any] = ["type": k.text == nil ? "rawKeyDown" : "keyDown", "key": k.key, "code": k.code,
                                   "windowsVirtualKeyCode": k.vk, "nativeVirtualKeyCode": k.vk]
        if let t = k.text { down["text"] = t }
        try await requirePage().call("Input.dispatchKeyEvent", down)
        try await requirePage().call("Input.dispatchKeyEvent", ["type": "keyUp", "key": k.key, "code": k.code,
                                                               "windowsVirtualKeyCode": k.vk, "nativeVirtualKeyCode": k.vk])
    }

    // MARK: Helpers

    /// PID of the process listening on a TCP port (the stage's Chrome).
    private static func listeningPID(port: Int) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { pid_t($0) }.first
    }
}
