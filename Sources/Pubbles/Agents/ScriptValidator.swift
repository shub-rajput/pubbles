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

    struct Report {
        var problems: [String] = []
        var estimatedSeconds: Double = 0
        var steps = 0
    }

    /// Structure and rules only; no page needed.
    func check(_ script: TakeScript) -> Report {
        var report = Report()
        if script.format != 1 { report.problems.append("format must be 1") }
        if script.name.trimmingCharacters(in: .whitespaces).isEmpty { report.problems.append("name is empty") }
        if URL(string: script.url)?.scheme?.hasPrefix("http") != true { report.problems.append("url must be an http(s) URL") }
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
                if Self.needsTarget.contains(step.action) && step.target == nil { problem("needs a target") }
                report.estimatedSeconds += estimate(step)

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
        var report = check(script)
        try await stage.open(url: script.url, viewport: script.viewportSize)
        for (i, scene) in script.scenes.enumerated() {
            for (j, step) in scene.steps.enumerated() {
                let at = "Scene \(i + 1) \"\(scene.title)\", step \(j + 1) (\(step.action))"
                if let target = step.target, try await stage.viewportRect(target) == nil {
                    report.problems.append("\(at): can't find \"\(target)\" on the page at this point")
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

    /// Rough playing time of a step, matching TakePlayer's pacing.
    private func estimate(_ step: TakeScript.Step) -> Double {
        let typing = Double(step.text?.count ?? 0) / 22 * 1.1
        switch step.action {
        case "point", "click": return step.duration ?? 0.7
        case "say": return typing + 0.2
        case "type": return typing
        case "newline", "clear", "key": return 0.12
        case "pin", "dismiss": return 0.2
        case "hide": return 0.15
        case "circle": return (step.duration ?? 0.9) + 0.75
        case "underline": return (step.duration ?? 0.35) + 0.75
        case "arrow": return (step.duration ?? 0.45) + 1.4
        case "scroll": return (step.duration ?? 0.9) + 0.4
        case "wait": return step.seconds ?? 1
        default: return 0
        }
    }
}
