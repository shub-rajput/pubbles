import AppKit

/// The tools Pubbles offers agents over MCP, and the instructions that teach them the flow.
@MainActor
final class AgentTools {
    private let takes: TakeController
    private let live: LivePresenter
    /// The connected agent's name (from MCP initialize), recorded as a script's author.
    var clientName = "Agent"

    init(takes: TakeController, live: LivePresenter) {
        self.takes = takes
        self.live = live
    }

    private var stage: Stage { takes.stage }
    private var config: AgentsConfig { ConfigManager.shared.config.agents }
    private var charLimit: Int { ConfigManager.shared.config.behavior.charLimit }

    // MARK: Instructions

    var instructions: String {
        """
        Pubbles makes short explainer videos of web pages: a pointer with subtitle bubbles and doodles, played on \
        Pubbles' own browser window (the stage) and recorded. The user's mouse and keyboard are never used.

        Flow:
        1. open_page(url), then outline(), screenshot() and scroll_to() to learn the page. outline() targets work as-is.
        2. Propose the storyboard in chat as a numbered scene list (what the bubble says, what gets pointed at or \
        doodled, rough timing). Iterate with the user until they agree. Don't save before that.
        3. validate_script(script) and fix every problem it reports.
        4. save_script(id, script). Each save is a new version (v1, v2…); pass replace: true only if the user asked \
        to overwrite. It then shows in Pubbles' menubar under Scripts.
        5. rehearse(id) (if the user allows it) to check it plays; fix, save and rehearse again if a scene fails. \
        preview_scene(id, scene) plays up to the end of a scene and returns a snapshot with the bubbles, pins and \
        doodles, to check nothing important is covered. prepare_stage(id) sets the stage up without playing, if \
        you want the user to look first.
        6. Recording: the user presses Record in Pubbles, or asks you to and record(id) is allowed. You get the \
        video path back. Changes later: get_script, edit, save_script (new version).

        Script: {"format":1, "name", "url", "viewport":[1440,900], "scenes":[{"title", "steps":[...]}]}. Steps, by "do":
        - point {target, anchor?: center|left|right|above|below, offset?: [dx,dy]}: glide the pointer there
        - say {text}: bubble on, then type it. "\\n" starts a new line; each line at most \(charLimit) characters
        - newline, clear: in the bubble. pin: leave the bubble pinned at the pointer (needs text)
        - hide: bubble off, pins stay. dismiss: bubble and pins off
        - circle {target, pad?}, underline {target}, arrow {target, from?: [dx,dy]}: doodles (the bubble comes on)
        - scroll {target, align?: 0–1, where its top lands in the viewport} or {by: pixels}
        - click {target}, type {text}, key {key: escape|return|space|tab|pageup|pagedown|up|down}: act on the page
        - wait {seconds}
        Optional "duration" on point/click/circle/underline/arrow/scroll sets its speed in seconds.
        Targets: a CSS selector or "text:Some words" (innermost visible element containing them).

        App scripts (native apps instead of a web page): give "windows": [{"app", "title"?}, …] and optionally \
        "layout" (side_by_side, the default; displays; as_is) instead of "url". Steps point at \
        "element": {"app", "title", "role"?, "window"?, "index"?} (found through Accessibility when the step plays; \
        inspect_app lists what's there) instead of "target". App scripts can point, say, doodle, pin, clear, hide, \
        dismiss and wait; scroll, click, type and key are web-only for now. A take arranges the windows (keeping \
        their sizes), records just them, and puts them back afterwards.

        Add "optional": true to a step whose target may not appear (cookie banners); the take skips it if missing.

        Placement: the bubble's top-left corner sits about 12px below-right of the pointer, and it grows right and \
        down, up to about 300px wide. A pin stays exactly where the bubble was. To keep page copy readable, point \
        at empty space beside what you're explaining (anchor right/below plus an offset), and check with preview_scene.

        Every take (menubar or tool) opens a fresh stage window in front, centred, and checks it's visible; if it \
        can't, the take doesn't start and the result has a code (stage_not_visible, stage_occluded, \
        viewport_too_large, permission_missing:screen_recording). Results include a "stage" block.

        Live mode (any app, nothing recorded): to point at and explain things anywhere on screen while you \
        work with the user. Start with live_focus(app, title?) so the window you're talking about is in front \
        (it returns that window's frame); or pass app on any live action. If the explanation spans apps, \
        live_focus(windows: [{app}, {app}]) shows them side by side (positions change, so use the frames it \
        returns); they go back where they were on live_end. Then live_point, live_say, \
        live_circle, live_underline, live_arrow, live_pin, live_clear, live_hide_bubble, and live_end when done. Positions are screen points from the top-left \
        of the main display (the space macOS Accessibility frames use), so find them with a computer-use or \
        accessibility tool first. The pointer starts where the user's mouse is; give the user time to read \
        each bubble. Live mode ends after a minute without calls, on Esc, or when a take starts.

        Rules: doodles and pins stay fixed on the screen, not the page. Doodles are cleared before each scroll \
        automatically; dismiss pins before scrolling. Give each bubble time to be read (a wait of about 1s per 4–5 \
        words). Keep videos short, one idea per scene, and keep the pointer near what the bubble talks about.
        """
    }

    // MARK: Definitions

    private static let stepSchema: [String: Any] = [
        "type": "object",
        "required": ["do"],
        "properties": [
            "do": ["type": "string", "enum": ScriptValidator.actions.sorted()],
            "target": ["type": "string", "description": "web scripts: CSS selector or \"text:Some words\""],
            "element": ["type": "object", "required": ["app", "title"], "description": "app scripts: an element found through Accessibility",
                        "properties": ["app": ["type": "string"], "title": ["type": "string", "description": "label it shows, contains"],
                                       "role": ["type": "string"], "window": ["type": "string"], "index": ["type": "integer"]]],
            "optional": ["type": "boolean"],
            "anchor": ["type": "string", "enum": ["center", "left", "right", "above", "below"]],
            "offset": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
            "text": ["type": "string"],
            "key": ["type": "string", "enum": ScriptValidator.keys.sorted()],
            "by": ["type": "number", "description": "scroll pixels, positive = down"],
            "align": ["type": "number", "description": "scroll: where the target's top lands, 0–1 of the viewport height"],
            "from": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2,
                     "description": "arrow start relative to its tip"],
            "pad": ["type": "number"],
            "duration": ["type": "number", "description": "seconds"],
            "seconds": ["type": "number", "description": "wait length"],
        ],
    ]

    private static let scriptSchema: [String: Any] = [
        "type": "object",
        "required": ["name", "scenes"],
        "properties": [
            "format": ["type": "integer", "enum": [1]],
            "name": ["type": "string", "description": "shown to the user, e.g. \"pubbles.app tour\""],
            "url": ["type": "string", "description": "web script: the page (give url or windows)"],
            "windows": ["type": "array", "description": "app script: the windows it shows (give url or windows)",
                        "items": ["type": "object", "required": ["app"],
                                  "properties": ["app": ["type": "string"], "title": ["type": "string"]]]],
            "layout": ["type": "string", "enum": ["side_by_side", "displays", "as_is"]],
            "viewport": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2,
                         "description": "[width, height] of the page in the video; default [1440, 900]"],
            "scenes": ["type": "array", "items": [
                "type": "object",
                "required": ["title", "steps"],
                "properties": ["title": ["type": "string"], "steps": ["type": "array", "items": stepSchema]],
            ]],
        ],
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    var definitions: [[String: Any]] {
        let idVersion: [String: Any] = ["id": ["type": "string"], "version": ["type": "integer", "description": "default: latest"]]
        let num: [String: Any] = ["type": "number"]
        let target: [String: Any] = ["app": ["type": "string", "description": "bring this app's window to the front first (name or bundle id)"],
                                     "title": ["type": "string", "description": "which of its windows (title contains)"]]
        func live(_ props: [String: Any]) -> [String: Any] { props.merging(target) { a, _ in a } }
        let rect = live(["x": num, "y": num, "width": num, "height": num, "duration": num])
        return [
            Self.tool("open_page", "Open a URL in Pubbles' stage window (a separate browser window sized for the video) and load it fresh.",
                      ["url": ["type": "string"], "width": ["type": "number"], "height": ["type": "number"]], required: ["url"]),
            Self.tool("outline", "Headings, buttons, links, images and fields on the stage page, with a target to use in scripts, their position on the page (pageY) and whether they're in view.",
                      ["limit": ["type": "integer"]]),
            Self.tool("screenshot", "Screenshot of the stage page's current view."),
            Self.tool("scroll_to", "Scroll the stage page instantly (for looking around) to a target or a y position.",
                      ["target": ["type": "string"], "y": ["type": "number"]]),
            Self.tool("validate_script", "Check a script: structure, bubble rules, line length, and (check_page, default true) that every target is on the page where the take will need it. Returns problems to fix and an estimated length.",
                      ["script": Self.scriptSchema, "check_page": ["type": "boolean"]], required: ["script"]),
            Self.tool("save_script", "Validate and save a script into Pubbles as a new version (v1, v2…), or over the latest version with replace. It then appears in Pubbles under Scripts.",
                      ["id": ["type": "string", "description": "lowercase-with-dashes, e.g. \"pubbles-app-tour\""],
                       "script": Self.scriptSchema, "replace": ["type": "boolean"]], required: ["id", "script"]),
            Self.tool("list_scripts", "Scripts saved in Pubbles, with their versions."),
            Self.tool("get_script", "A saved script's JSON.", idVersion, required: ["id"]),
            Self.tool("rehearse", "Play a saved script on the stage without recording, and wait for it to end. Returns whether it finished, and which scene and step failed if not. Only if the user allows agents to rehearse.",
                      idVersion, required: ["id"]),
            Self.tool("record", "Record a saved script (3-2-1 countdown, then the take) and wait for it to end. Returns the video path. Only when the user asks you to record and allows agents to record.",
                      idVersion, required: ["id"]),
            Self.tool("preview_scene", "Play a saved script up to the end of one scene (1-based) and return a snapshot of the stage with Pubbles' bubbles, pins and doodles, to check placement. Same permission as rehearse.",
                      ["id": ["type": "string"], "scene": ["type": "integer"], "version": ["type": "integer"]], required: ["id", "scene"]),
            Self.tool("inspect_app", "An open app's windows and labelled elements (role, title, frame in screen points), to write \"element\" targets for app scripts or find positions for live mode. Filter with query.",
                      ["app": ["type": "string"], "window": ["type": "string", "description": "window title contains"],
                       "query": ["type": "string"], "limit": ["type": "integer"]], required: ["app"]),
            Self.tool("prepare_stage", "Open a fresh stage window for a saved script, in front and centred, and report whether it's visible. Doesn't play anything; use it to let the user look before a take.",
                      idVersion, required: ["id"]),
            Self.tool("stop_take", "Stop the take that's playing."),
            Self.tool("live_focus", "Live mode: bring an app's window to the front (launching the app if needed) and check it's visible, so the user sees what you point at. Returns the window's frame in screen points. For something that spans apps, pass windows: [{app, title?}, …] instead; they're laid out side by side (or one per display, or as they are) so all are visible, and moved back when live mode ends.",
                      target.merging([
                          "windows": ["type": "array", "items": ["type": "object", "required": ["app"], "properties": [
                              "app": ["type": "string"], "title": ["type": "string"]]]],
                          "layout": ["type": "string", "enum": ["side_by_side", "displays", "as_is"], "description": "for windows; default side_by_side"],
                      ]) { a, _ in a }),
            Self.tool("live_point", "Live mode: glide Pubbles' pointer to a screen position (points, top-left of the main display).",
                      live(["x": num, "y": num, "duration": num]), required: ["x", "y"]),
            Self.tool("live_say", "Live mode: show a new message in the bubble at the pointer (replaces the previous one). Optionally glide to x, y first. \"\\n\" starts a new line; lines up to \(charLimit) characters.",
                      live(["text": ["type": "string"], "x": num, "y": num]), required: ["text"]),
            Self.tool("live_circle", "Live mode: doodle a loose circle around a screen rect.", rect, required: ["x", "y", "width", "height"]),
            Self.tool("live_underline", "Live mode: doodle an underline under a screen rect.", rect, required: ["x", "y", "width", "height"]),
            Self.tool("live_arrow", "Live mode: doodle an arrow pointing at x, y (from from_x, from_y, default up-left of it).",
                      live(["x": num, "y": num, "from_x": num, "from_y": num]), required: ["x", "y"]),
            Self.tool("live_pin", "Live mode: leave the current bubble pinned where it is."),
            Self.tool("live_clear", "Live mode: clear the bubble's text and the doodles (pins stay)."),
            Self.tool("live_hide_bubble", "Live mode: hide the bubble (pins and the pointer stay)."),
            Self.tool("live_end", "Live mode: remove the pointer, bubble, pins and doodles."),
            Self.tool("take_status", "Whether a take is playing (and which scene), and how the last one ended."),
        ]
    }

    // MARK: Calls

    func call(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "open_page": return try await openPage(args)
            case "outline": return text(json(try await requireStage().outline(limit: args["limit"] as? Int ?? 150)))
            case "screenshot":
                let jpeg = try await requireStage().screenshot()
                return ["content": [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]]
            case "scroll_to": return try await scrollTo(args)
            case "validate_script": return try await validate(args)
            case "save_script": return try await save(args)
            case "list_scripts":
                return text(json(ScriptStore.list().map { ["id": $0.id, "name": $0.name, "versions": $0.versions] }))
            case "get_script": return try getScript(args)
            case "rehearse": return try await runTake(args, kind: .rehearsal)
            case "preview_scene": return try await runTake(args, kind: .preview)
            case "prepare_stage": return try await prepareStage(args)
            case "inspect_app": return try inspectApp(args)
            case "record": return try await runTake(args, kind: .recording)
            case "live_focus":
                try requireIdle()
                if let list = args["windows"] as? [[String: Any]], !list.isEmpty {
                    let windows = try list.map { w -> (app: String, title: String?) in
                        guard let app = w["app"] as? String else { throw TakeError.script("each window needs an app") }
                        return (app, w["title"] as? String)
                    }
                    let raw = args["layout"] as? String ?? "side_by_side"
                    guard let layout = WindowFocus.Layout(rawValue: raw) else {
                        throw TakeError.script("layout is side_by_side, displays or as_is")
                    }
                    let states = try await live.arrange(windows, layout: layout)
                    return text(json(states.map { name, state in state.report.merging(["app": name]) { a, _ in a } }))
                }
                guard let app = args["app"] as? String else { throw TakeError.script("pass app, or windows for several") }
                return text(json(try await live.focus(app: app, title: args["title"] as? String).report))
            case "live_point", "live_say", "live_circle", "live_underline", "live_arrow",
                 "live_pin", "live_clear", "live_hide_bubble":
                return try await liveCall(name, args)
            case "live_end":
                live.end()
                return text("Live mode ended.")
            case "stop_take":
                takes.stop()
                return text(takes.isRunning ? "Stopping the take." : "No take is playing.")
            case "take_status":
                var status: [String: Any] = ["playing": takes.isRunning]
                if let scene = takes.sceneLabel { status["scene"] = scene }
                if let last = takes.lastResult { status["last"] = last }
                if stage.isOpen { status["stage"] = stage.windowState().report }
                return text(json(status))
            default:
                return failure("Unknown tool \(name)")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func openPage(_ args: [String: Any]) async throws -> [String: Any] {
        try requireIdle()
        guard let url = args["url"] as? String, URL(string: url)?.scheme?.hasPrefix("http") == true else {
            throw TakeError.script("url must be an http(s) URL")
        }
        let size = CGSize(width: (args["width"] as? NSNumber)?.doubleValue ?? 1440,
                          height: (args["height"] as? NSNumber)?.doubleValue ?? 900)
        try await stage.open(url: url, viewport: size)
        return text("Stage open at \(url), viewport \(Int(size.width))×\(Int(size.height)), in the background (the user's work isn't interrupted). Use outline() and screenshot() to look around. Takes open a fresh stage in front automatically.")
    }

    private func scrollTo(_ args: [String: Any]) async throws -> [String: Any] {
        let stage = try await requireStage()
        if let target = args["target"] as? String {
            guard let r = try await stage.viewportRect(target) else { throw TakeError.target(target) }
            try await stage.jumpScroll(to: try await stage.scrollY() + Double(r.minY) - 0.15 * Double(stage.viewport.height))
        } else if let y = (args["y"] as? NSNumber)?.doubleValue {
            try await stage.jumpScroll(to: y)
        } else {
            throw TakeError.script("pass a target or y")
        }
        return text("Scrolled to y=\(Int(try await stage.scrollY())).")
    }

    private func validate(_ args: [String: Any]) async throws -> [String: Any] {
        let script = try decodeScript(args["script"])
        let validator = ScriptValidator(charLimit: charLimit)
        let report: ScriptValidator.Report
        if args["check_page"] as? Bool ?? true {
            try requireIdle()
            report = try await validator.check(script, on: stage)
        } else {
            report = validator.check(script)
        }
        return text(describe(report, script))
    }

    private func save(_ args: [String: Any]) async throws -> [String: Any] {
        try requireIdle()
        guard let id = args["id"] as? String else { throw TakeError.script("id is required") }
        var script = try decodeScript(args["script"])
        let report = try await ScriptValidator(charLimit: charLimit).check(script, on: stage)
        guard report.problems.isEmpty else {
            return failure("Not saved. Fix these first:\n" + describe(report, script))
        }
        script.author = TakeScript.Author(agent: clientName, updated: ISO8601DateFormatter().string(from: Date()))
        let version = try ScriptStore.save(script, id: id, replace: args["replace"] as? Bool ?? false)
        return text("Saved \"\(script.name)\" as \(id) v\(version) (\(script.scenes.count) scenes, about \(TakeController.clock(report.estimatedSeconds))). The user can find it in Pubbles' menubar under Scripts.")
    }

    private func getScript(_ args: [String: Any]) throws -> [String: Any] {
        let (id, version) = try scriptRef(args)
        let data = try Data(contentsOf: ScriptStore.fileURL(id: id, version: version))
        return text("\(id) v\(version):\n" + String(decoding: data, as: UTF8.self))
    }

    private func runTake(_ args: [String: Any], kind: TakeController.Kind) async throws -> [String: Any] {
        switch kind {
        case .rehearsal where !config.allowRehearse, .preview where !config.allowRehearse:
            throw TakeError.setup("The user hasn't allowed agents to rehearse. Ask them to press Rehearse in Pubbles (menubar → Scripts).")
        case .recording where !config.allowRecord:
            throw TakeError.setup("The user hasn't allowed agents to record. Ask them to press Record in Pubbles (menubar → Scripts), or to allow it there.")
        default: break
        }
        try requireIdle()
        let (id, version) = try scriptRef(args)
        live.end()
        var through: Int?
        if kind == .preview {
            let count = try ScriptStore.load(id: id, version: version).scenes.count
            guard let scene = (args["scene"] as? NSNumber)?.intValue, (1...count).contains(scene) else {
                throw TakeError.script("scene must be 1–\(count)")
            }
            through = scene
        }
        takes.start(id: id, version: version, kind: kind, throughScene: through)
        guard let result = await takes.waitForEnd() else { throw TakeError.setup("The take didn't start") }
        var out: [String: Any] = ["finished": result.finished, "stopped": result.stopped,
                                  "length": TakeController.clock(result.seconds), "script": "\(id) v\(version)"]
        if let error = result.error { out["error"] = error }
        if let code = result.errorCode { out["code"] = code }
        if let file = result.file { out["video"] = file }
        if result.stopped { out["note"] = "The user stopped it (Esc or Stop)." }
        if var stage = result.stageAtStart?.report {
            stage["coveredDuringTake"] = result.coveredDuringTake
            out["stage"] = stage
        }
        var content: [[String: Any]] = [["type": "text", "text": json(out)]]
        if let jpeg = result.snapshot {
            content.insert(["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"], at: 0)
        }
        var reply: [String: Any] = ["content": content]
        if !result.finished { reply["isError"] = true }
        return reply
    }

    private func liveCall(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        try requireIdle()
        func number(_ key: String) -> CGFloat? { (args[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        func point() throws -> CGPoint {
            guard let x = number("x"), let y = number("y") else { throw TakeError.script("x and y are required") }
            return CGPoint(x: x, y: y)
        }
        func rect() throws -> CGRect {
            guard let w = number("width"), let h = number("height") else { throw TakeError.script("x, y, width and height are required") }
            return CGRect(origin: try point(), size: CGSize(width: w, height: h))
        }
        let duration = (args["duration"] as? NSNumber)?.doubleValue
        if let app = args["app"] as? String {
            try await live.focus(app: app, title: args["title"] as? String)
        }
        switch name {
        case "live_point": try await live.point(at: try point(), duration: duration)
        case "live_say":
            guard let text = args["text"] as? String, !text.isEmpty else { throw TakeError.script("text is required") }
            try await live.say(text, at: number("x") == nil ? nil : try point())
        case "live_circle": try await live.circle(try rect(), duration: duration)
        case "live_underline": try await live.underline(try rect(), duration: duration)
        case "live_arrow":
            let from = number("from_x").flatMap { fx in number("from_y").map { CGPoint(x: fx, y: $0) } }
            try await live.arrow(to: try point(), from: from)
        case "live_pin": try await live.pin()
        case "live_clear": try await live.clear()
        default: try await live.hideBubble()
        }
        return text("ok")
    }

    private func inspectApp(_ args: [String: Any]) throws -> [String: Any] {
        guard let app = args["app"] as? String else { throw TakeError.script("app is required") }
        guard let running = AXFinder.runningApp(app) else {
            throw TakeError.script("\(app) isn't open; live_focus(app) opens it")
        }
        let windows = WindowFocus.windows(running.processIdentifier).compactMap { w -> [String: Any]? in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            guard let f = WindowFocus.axFrame(w) else { return nil }
            return ["title": title as? String ?? "", "frame": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)]]
        }
        let query = (args["query"] as? String)?.lowercased()
        let limit = args["limit"] as? Int ?? 200
        let elements = AXFinder.elements(app: app, window: args["window"] as? String)
            .filter { query == nil || $0.label.lowercased().contains(query!) || $0.role.lowercased().contains(query!) }
            .prefix(limit)
            .map { e -> [String: Any] in
                ["role": e.role, "title": String(e.label.prefix(80)), "window": e.window,
                 "frame": [Int(e.frame.minX), Int(e.frame.minY), Int(e.frame.width), Int(e.frame.height)]]
            }
        return text(json(["app": running.localizedName ?? app, "windows": windows, "elements": Array(elements)]))
    }

    private func prepareStage(_ args: [String: Any]) async throws -> [String: Any] {
        try requireIdle()
        let (id, version) = try scriptRef(args)
        let script = try ScriptStore.load(id: id, version: version)
        guard let url = script.url, !script.isAppScript else {
            throw TakeError.script("prepare_stage is for web scripts; an app script arranges its windows when the take starts (live_focus with the same windows shows the layout)")
        }
        live.end()
        try await stage.open(url: url, viewport: script.viewportSize, forTake: true)
        let state = stage.windowState().report
        return text(json(["script": "\(id) v\(version)", "stage": state,
                          "note": "The stage is open in front. Ask the user if they can see it before a take."]))
    }

    // MARK: Helpers

    private func requireIdle() throws {
        if takes.isRunning { throw TakeError.setup("A take is playing on the stage; wait for it or stop_take() first") }
    }

    private func requireStage() async throws -> Stage {
        try requireIdle()
        guard stage.isOpen else { throw TakeError.setup("The stage isn't open; call open_page(url) first") }
        return stage
    }

    private func scriptRef(_ args: [String: Any]) throws -> (String, Int) {
        guard let id = args["id"] as? String, let entry = ScriptStore.list().first(where: { $0.id == id }) else {
            throw TakeError.script("No script with that id; list_scripts() shows what's saved")
        }
        let version = (args["version"] as? NSNumber)?.intValue ?? entry.latest
        guard entry.versions.contains(version) else {
            throw TakeError.script("\(id) has versions \(entry.versions.map { "v\($0)" }.joined(separator: ", "))")
        }
        return (id, version)
    }

    private func decodeScript(_ value: Any?) throws -> TakeScript {
        guard var dict = value as? [String: Any] else { throw TakeError.script("script must be an object") }
        if dict["format"] == nil { dict["format"] = 1 }
        let data = try JSONSerialization.data(withJSONObject: dict)
        do {
            return try JSONDecoder().decode(TakeScript.self, from: data)
        } catch let error as DecodingError {
            throw TakeError.script("script doesn't match the format: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "missing \"\(key.stringValue)\" at script\(path(ctx.codingPath))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "wrong type at script\(path(ctx.codingPath))"
        @unknown default: return "\(error)"
        }
    }

    private func describe(_ report: ScriptValidator.Report, _ script: TakeScript) -> String {
        var out = "\(script.scenes.count) scenes, \(report.steps) steps, about \(TakeController.clock(report.estimatedSeconds))."
        if report.problems.isEmpty { out = "OK. " + out }
        if !report.notes.isEmpty { out += "\nNotes:\n" + report.notes.map { "- " + $0 }.joined(separator: "\n") }
        if !report.problems.isEmpty { out += "\nProblems:\n" + report.problems.map { "- " + $0 }.joined(separator: "\n") }
        return out
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }
    private func failure(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": true] }
}
