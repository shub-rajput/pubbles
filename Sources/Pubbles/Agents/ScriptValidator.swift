import Foundation

/// Checks a script before it's saved or played: structure, the bubble rules, line length, and (with
/// the stage) that every target exists where the take will need it. Problems are phrased as what to
/// fix, since agents read them.
@MainActor
struct ScriptValidator {
    let charLimit: Int

    static let actions: Set<String> = ["point", "say", "newline", "clear", "pin", "hide", "dismiss", "circle",
                                       "underline", "arrow", "scroll", "click", "type", "key", "wait"]
    static let keys: Set<String> = ["escape", "return", "space", "tab", "pagedown", "pageup", "down", "up"]
    private static let needsTarget: Set<String> = ["point", "click", "circle", "underline", "arrow"]
    /// Actions that act on a web page; app scripts only point, explain and doodle (for now).
    static let webOnly: Set<String> = ["scroll", "click", "type", "key"]

    struct Report {
        var problems: [String] = []
        var notes: [String] = []
        var estimatedSeconds: Double = 0
        var steps = 0
    }

    /// Structure and rules only; no page needed.
    func check(_ script: TakeScript) -> Report {
        var report = Report()
        if script.format != 1 { report.problems.append("format must be 1") }
        if script.name.trimmingCharacters(in: .whitespaces).isEmpty { report.problems.append("name is empty") }
        if script.isAppScript {
            if script.url != nil { report.problems.append("a script has either url (a web page) or windows (apps), not both") }
            if let layout = script.layout, WindowFocus.Layout(rawValue: layout) == nil {
                report.problems.append("layout is side_by_side, displays or as_is")
            }
        } else if URL(string: script.url ?? "")?.scheme?.hasPrefix("http") != true {
            report.problems.append("url must be an http(s) URL (or give windows for an app script)")
        }
        if script.scenes.isEmpty { report.problems.append("add at least one scene") }

        var bubble = false, bubbleHasText = false, pins = 0
        for (i, scene) in script.scenes.enumerated() {
            if scene.steps.isEmpty { report.problems.append("Scene \(i + 1) \"\(scene.title)\" has no steps") }
            for (j, step) in scene.steps.enumerated() {
                report.steps += 1
                let at = "Scene \(i + 1) \"\(scene.title)\", step \(j + 1) (\(step.action))"
                func problem(_ text: String) { report.problems.append("\(at): \(text)") }

                guard Self.actions.contains(step.action) else {
                    problem("unknown action; use one of \(Self.actions.sorted().joined(separator: ", "))")
                    continue
                }
                if script.isAppScript {
                    if step.target != nil { problem("app scripts point at elements: use \"element\": {\"app\", \"title\"} instead of target") }
                    if Self.webOnly.contains(step.action) { problem("\(step.action) isn't supported in app scripts yet") }
                    if Self.needsTarget.contains(step.action) && step.element == nil { problem("needs an element") }
                    if let app = step.element?.app, let windows = script.windows,
                       !windows.contains(where: { $0.app.caseInsensitiveCompare(app) == .orderedSame }) {
                        problem("\(app) isn't in the script's windows, so it won't be arranged on screen")
                    }
                } else {
                    if step.element != nil { problem("element is for app scripts; web scripts use target") }
                    if Self.needsTarget.contains(step.action) && step.target == nil { problem("needs a target") }
                }
                report.estimatedSeconds += estimate(step) * 1.08 // per-step overhead (page round trips, settling)

                switch step.action {
                case "say":
                    guard let text = step.text, !text.isEmpty else { problem("needs text"); continue }
                    for line in text.components(separatedBy: "\n") where line.count > charLimit {
                        problem("\"\(line)\" is \(line.count) characters; bubble lines fit \(charLimit). Split it with \\n or shorten it")
                    }
                    bubble = true
                    bubbleHasText = true
                case "newline", "clear":
                    if !bubble { problem("the bubble isn't on here; add a say first") }
                    if step.action == "clear" { bubbleHasText = false }
                case "pin":
                    if !bubble || !bubbleHasText { problem("pin needs text in the bubble; add a say first") }
                    pins += 1
                    bubbleHasText = false
                case "hide":
                    bubble = false
                    bubbleHasText = false
                case "dismiss":
                    bubble = false
                    bubbleHasText = false
                    pins = 0
                case "circle", "underline", "arrow":
                    bubble = true
                case "scroll":
                    if step.target == nil && step.by == nil { problem("needs a target or by") }
                    if pins > 0 { problem("pins stay fixed on screen while the page scrolls; add a dismiss before it") }
                case "type":
                    if step.text?.isEmpty ?? true { problem("needs text") }
                case "key":
                    if !Self.keys.contains(step.key?.lowercased() ?? "") {
                        problem("unknown key; use one of \(Self.keys.sorted().joined(separator: ", "))")
                    }
                default:
                    break
                }
            }
        }
        return report
    }

    /// Structure plus a dry pass on the live page: scrolls jump instead of easing, nothing is
    /// clicked, and every target is looked up where the take will look for it.
    func check(_ script: TakeScript, on stage: Stage) async throws -> Report {
        if script.isAppScript { return checkApps(script) }
        var report = check(script)
        try await stage.open(url: script.url ?? "", viewport: script.viewportSize)
        for (i, scene) in script.scenes.enumerated() {
            for (j, step) in scene.steps.enumerated() {
                let at = "Scene \(i + 1) \"\(scene.title)\", step \(j + 1) (\(step.action))"
                if let target = step.target, try await stage.viewportRect(target) == nil {
                    if step.optional == true {
                        report.notes.append("\(at): \"\(target)\" isn't on the page right now; it's optional, so the take will skip it")
                    } else {
                        report.problems.append("\(at): can't find \"\(target)\" on the page at this point (if it only sometimes appears, like a cookie banner, add \"optional\": true)")
                    }
                    continue
                }
                guard step.action == "scroll" else { continue }
                let y = try await stage.scrollY()
                if let target = step.target, let r = try await stage.viewportRect(target) {
                    let to = y + Double(r.minY) - (step.align ?? 0.15) * Double(stage.viewport.height)
                    try await stage.jumpScroll(to: min(max(0, to), try await stage.maxScrollY()))
                } else if let by = step.by {
                    try await stage.jumpScroll(to: y + by)
                }
            }
        }
        try await stage.jumpScroll(to: 0)
        return report
    }

    /// Structure plus a live check that each element exists in the running apps. Nothing is moved
    /// or launched; an app that isn't open can't be checked yet (the take opens it).
    func checkApps(_ script: TakeScript) -> Report {
        var report = check(script)
        var closed = Set<String>()
        for window in script.windows ?? [] where AXFinder.runningApp(window.app) == nil {
            closed.insert(window.app)
            report.notes.append("\(window.app) isn't open, so its elements can't be checked yet (the take opens it)")
        }
        for (i, scene) in script.scenes.enumerated() {
            for (j, step) in scene.steps.enumerated() {
                guard let e = step.element, !closed.contains(e.app) else { continue }
                let at = "Scene \(i + 1) \"\(scene.title)\", step \(j + 1) (\(step.action))"
                if AXFinder.find(app: e.app, title: e.title, role: e.role, window: e.window, index: e.index ?? 0) == nil {
                    if step.optional == true {
                        report.notes.append("\(at): \"\(e.title)\" isn't in \(e.app) right now; it's optional, so the take will skip it")
                    } else {
                        report.problems.append("\(at): can't find \"\(e.title)\" in \(e.app)\(e.window.map { "'s \"\($0)\" window" } ?? ""); inspect_app shows what's there")
                    }
                }
            }
        }
        return report
    }

    /// Rough playing time of a step, matching TakePlayer's pacing: glides settle on a spring after
    /// their eased path, typing averages ~0.052s a character with pauses on spaces and punctuation,
    /// and scrolls add a settle and a check of where they landed.
    private func estimate(_ step: TakeScript.Step) -> Double {
        let chars = Double(step.text?.count ?? 0)
        let lines = Double(step.text?.components(separatedBy: "\n").count ?? 1)
        switch step.action {
        case "point": return (step.duration ?? 0.55) + 0.25
        case "click": return (step.duration ?? 0.55) + 0.5
        case "say": return 0.18 + chars * 0.052 + (lines - 1) * 0.12
        case "type": return chars * 0.058
        case "newline", "clear", "key": return 0.12
        case "pin", "dismiss": return 0.2
        case "hide": return 0.15
        case "circle": return (step.duration ?? 0.9) + 1.0
        case "underline": return (step.duration ?? 0.35) + 1.0
        case "arrow": return (step.duration ?? 0.45) + 2.1
        case "scroll": return (step.duration ?? 0.8) + 0.45
        case "wait": return step.seconds ?? 1
        default: return 0
        }
    }
}
