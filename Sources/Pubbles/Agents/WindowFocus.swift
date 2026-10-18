import AppKit
import ApplicationServices

/// Bring any app's window to the front and check it's really visible: what a take does for the
/// stage, and what live mode does for whatever app the agent is explaining. Raising goes through
/// Accessibility as well as activation, since macOS ignores activation requests from a background
/// app like Pubbles; visibility comes from the window server's front-to-back list.
@MainActor
enum WindowFocus {
    /// What a window looks like on screen right now.
    struct State: Sendable {
        var onScreen = false     // on the current Space, not minimised or hidden
        var frontmost = false    // no normal window above it
        var covered = 0.0        // fraction of it covered by other windows
        var frame: CGRect?
        var display: String?

        var visible: Bool { onScreen && covered < 0.02 }

        var report: [String: Any] {
            var r: [String: Any] = ["visible": visible, "frontmost": frontmost, "onScreen": onScreen,
                                    "coveredPercent": Int((covered * 100).rounded())]
            if let f = frame { r["frame"] = [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)] }
            if let display { r["display"] = display }
            return r
        }
    }

    // MARK: Raising

    /// Raise an app's window (or all its windows) over other apps, restoring it if minimised.
    static func raise(pid: pid_t, window: AXUIElement? = nil) {
        if pid == ProcessInfo.processInfo.processIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        } else if let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate(options: [.activateAllWindows])
        }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for w in window.map({ [$0] }) ?? windows(pid) {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
    }

    /// An app's window, found by app name or bundle id (launched if needed) and title.
    struct Target {
        let pid: pid_t
        let name: String
        let window: AXUIElement
        var frame: CGRect? { WindowFocus.axFrame(window) }
    }

    /// Find an app (by name or bundle id, launching it if needed) and one of its windows (title
    /// contains `title`, else its main window).
    static func resolve(app query: String, title: String?) async throws -> Target {
        let app = try await runningApp(query)
        let pid = app.processIdentifier
        let name = app.localizedName ?? query
        let deadline = Date().addingTimeInterval(8) // a just-launched app may take a moment to open a window
        while true {
            if let window = pickWindow(pid: pid, title: title) { return Target(pid: pid, name: name, window: window) }
            if Date() > deadline {
                throw TakeError.stage(code: "target_not_ready", message:
                    title.map { "\(name) has no window titled like \"\($0)\"" } ?? "\(name) has no open window")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Bring an app's window to the front and verify it's visible.
    static func focus(app query: String, title: String?) async throws -> State {
        let target = try await resolve(app: query, title: title)
        for attempt in 0..<4 {
            raise(pid: target.pid, window: target.window)
            try await Task.sleep(for: .milliseconds(200 + attempt * 150))
            let s = state(pid: target.pid, near: target.frame)
            if s.visible { return s }
        }
        throw problem(target, state(pid: target.pid, near: target.frame))
    }

    enum Layout: String {
        case sideBySide = "side_by_side" // next to each other at their own sizes, centred as a group
        case displays                    // one window per display, centred at its own size
        case asIs = "as_is"              // don't move anything, just bring them forward
    }

    /// Bring several windows forward together, laid out so all of them can be seen. Returns each
    /// one's state (in the given order) and where each window was before, to put them back later.
    static func arrange(_ targets: [Target], layout: Layout) async throws -> (states: [State], previous: [(AXUIElement, CGRect)]) {
        let previous = targets.compactMap { t in t.frame.map { (t.window, $0) } }
        let frames = layoutFrames(targets.map(\.frame), layout: layout)
        for (target, frame) in zip(targets, frames) {
            AXUIElementSetAttributeValue(target.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if let frame { setFrame(target.window, frame) }
        }
        var states: [State] = []
        for attempt in 0..<4 {
            // Raise in reverse, so with as_is the first window ends up on top.
            for target in targets.reversed() { raise(pid: target.pid, window: target.window) }
            try await Task.sleep(for: .milliseconds(250 + attempt * 150))
            states = targets.map { state(pid: $0.pid, near: $0.frame) }
            if layout == .asIs || states.allSatisfy(\.visible) { break }
        }
        if layout != .asIs, let i = states.firstIndex(where: { !$0.visible }) {
            throw problem(targets[i], states[i])
        }
        return (states, previous)
    }

    /// Put windows back where they were.
    static func restore(_ previous: [(AXUIElement, CGRect)]) {
        for (window, frame) in previous { setFrame(window, frame) }
    }

    private static func problem(_ target: Target, _ s: State) -> TakeError {
        if !s.onScreen {
            return .stage(code: "target_not_visible", message:
                "\(target.name)'s window isn't on screen (minimised, on another Space, or the screen is locked)")
        }
        return .stage(code: "target_occluded", message:
            "Another window still covers \(Int((s.covered * 100).rounded()))% of \(target.name)'s window")
    }

    /// New frames in global CoreGraphics coordinates (top-left origin), within the display's free
    /// area (no menu bar or Dock). Windows keep their own sizes and only shrink if they don't fit.
    /// nil = leave that window where it is.
    private static func layoutFrames(_ current: [CGRect?], layout: Layout) -> [CGRect?] {
        guard layout != .asIs, let primary = NSScreen.screens.first else { return current.map { _ in nil } }
        func freeArea(_ screen: NSScreen) -> CGRect {
            let v = screen.visibleFrame
            return CGRect(x: v.minX, y: primary.frame.height - v.maxY, width: v.width, height: v.height).insetBy(dx: 10, dy: 10)
        }
        func screen(containing frame: CGRect?) -> NSScreen {
            let center = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
            return NSScreen.screens.first { s in center.map { freeArea(s).insetBy(dx: -10, dy: -10).contains($0) } ?? false }
                ?? NSScreen.main ?? primary
        }
        let sizes = current.map { $0?.size ?? CGSize(width: 900, height: 700) }

        if layout == .displays {
            let screens = NSScreen.screens
            return sizes.enumerated().map { i, size in
                let area = freeArea(screens[min(i, screens.count - 1)])
                let w = min(size.width, area.width), h = min(size.height, area.height)
                return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
            }
        }

        // Side by side on the display the first window is on.
        let area = freeArea(screen(containing: current.first ?? nil))
        let gap: CGFloat = 16
        let available = area.width - gap * CGFloat(sizes.count - 1)
        var widths = sizes.map(\.width)
        if widths.reduce(0, +) > available {
            // Shrink only the windows wider than an equal share, just enough to fit.
            let share = available / CGFloat(widths.count)
            let narrow = widths.filter { $0 <= share }.reduce(0, +)
            let wideCount = CGFloat(widths.filter { $0 > share }.count)
            let wideWidth = (available - narrow) / max(1, wideCount)
            widths = widths.map { $0 > share ? wideWidth : $0 }
        }
        var x = area.midX - (widths.reduce(0, +) + gap * CGFloat(widths.count - 1)) / 2
        return zip(widths, sizes).map { w, size in
            let h = min(size.height, area.height)
            defer { x += w + gap }
            return CGRect(x: x, y: area.midY - h / 2, width: w, height: h)
        }
    }

    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    // MARK: Checking

    /// The app's on-screen window nearest `frame` (or its frontmost one), and how much of it is covered.
    static func state(pid: pid_t, near frame: CGRect? = nil) -> State {
        var state = State()
        guard pid != 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return state
        }
        func bounds(_ w: [String: Any]) -> CGRect? {
            (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        func isNormal(_ w: [String: Any]) -> Bool {
            (w[kCGWindowLayer as String] as? Int) == 0 && ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05
        }
        let candidates = list.indices.filter {
            (list[$0][kCGWindowOwnerPID as String] as? pid_t) == pid && isNormal(list[$0]) && (bounds(list[$0])?.width ?? 0) > 100
        }
        let index: Int?
        if let frame {
            // The one overlapping the expected frame most.
            index = candidates.max { a, b in
                area(bounds(list[a])?.intersection(frame)) < area(bounds(list[b])?.intersection(frame))
            }
        } else {
            index = candidates.first
        }
        guard let index, let found = bounds(list[index]) else { return state }

        state.onScreen = true
        state.frame = found
        // Normal windows in front of it. Pubbles' overlay sits on a higher layer, so it's not counted.
        let above = list[..<index].filter(isNormal)
        state.frontmost = above.isEmpty
        let coveredArea = above.compactMap { bounds($0)?.intersection(found) }.reduce(0.0) { $0 + area($1) }
        state.covered = min(1, coveredArea / max(1, area(found)))
        state.display = NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return id.map { CGDisplayBounds($0).contains(CGPoint(x: found.midX, y: found.midY)) } ?? false
        }?.localizedName
        return state
    }

    // MARK: Helpers

    private static func area(_ r: CGRect?) -> Double {
        guard let r, !r.isNull else { return 0 }
        return Double(r.width * r.height)
    }

    private static func runningApp(_ query: String) async throws -> NSRunningApplication {
        let matches: (NSRunningApplication) -> Bool = {
            $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
                || $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: matches) { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) ?? appURL(named: query) else {
            throw TakeError.stage(code: "target_open_failed", message: "Couldn't find an app called \"\(query)\"")
        }
        do {
            return try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw TakeError.stage(code: "target_open_failed", message: "Couldn't open \(query): \(error.localizedDescription)")
        }
    }

    private static func appURL(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", "\(home)/Applications"]
        return folders.map { URL(fileURLWithPath: "\($0)/\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func windows(_ pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func pickWindow(pid: pid_t, title: String?) -> AXUIElement? {
        let all = windows(pid)
        if let title {
            return all.first { (string($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(title) }
        }
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMainWindowAttribute as CFString, &main) == .success,
           let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
            return (main as! AXUIElement)
        }
        return all.first { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String } ?? all.first
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v as? String : nil
    }

    nonisolated static func axFrame(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
