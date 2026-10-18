import AppKit
import ApplicationServices

/// Finds elements in native apps through Accessibility, the way the stage finds CSS selectors in a
/// page: by app, a label the element shows (title, description or value), and optionally its role,
/// the window it's in, and which match to take.
@MainActor
enum AXFinder {
    struct Element {
        let role: String
        let label: String
        let frame: CGRect   // global screen points, top-left of the main display
        let window: String
    }

    /// Every labelled, visible element in the app's windows (or the one whose title contains
    /// `window`), in reading order.
    static func elements(app query: String, window: String? = nil, limit: Int = 3000) -> [Element] {
        guard let app = runningApp(query) else { return [] }
        var out: [Element] = []
        var visited = 0
        for win in WindowFocus.windows(app.processIdentifier) {
            let title = string(win, kAXTitleAttribute) ?? ""
            if let window, !title.localizedCaseInsensitiveContains(window) { continue }
            let bounds = WindowFocus.axFrame(win) ?? .null
            func walk(_ e: AXUIElement, depth: Int) {
                guard depth < 40, visited < limit else { return }
                visited += 1
                let label = [string(e, kAXTitleAttribute), string(e, kAXDescriptionAttribute), value(e)]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let label, let frame = WindowFocus.axFrame(e), frame.width > 1, frame.height > 1,
                   bounds.isNull || bounds.intersects(frame) {
                    out.append(Element(role: string(e, kAXRoleAttribute) ?? "", label: label, frame: frame, window: title))
                }
                for child in children(e) { walk(child, depth: depth + 1) }
            }
            for child in children(win) { walk(child, depth: 0) }
        }
        return out
    }

    /// The `index`-th element whose label contains `title` (ignoring case and spacing), optionally
    /// with a matching role ("button" or "AXButton").
    static func find(app: String, title: String, role: String? = nil, window: String? = nil, index: Int = 0) -> Element? {
        let wanted = normalize(title)
        let roleName = role.map { $0.hasPrefix("AX") ? $0 : "AX" + $0.prefix(1).uppercased() + $0.dropFirst() }
        let matches = elements(app: app, window: window).filter { e in
            normalize(e.label).contains(wanted) && (roleName == nil || e.role.caseInsensitiveCompare(roleName!) == .orderedSame)
        }
        // Prefer exact label matches over ones that merely contain the text.
        let exact = matches.filter { normalize($0.label) == wanted }
        let pool = exact.isEmpty ? matches : exact
        return index < pool.count ? pool[index] : nil
    }

    static func runningApp(_ query: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
                || $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame
        }
    }

    // MARK: Helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v as? String : nil
    }

    /// Text values only (not checkbox states and the like).
    private static func value(_ e: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
