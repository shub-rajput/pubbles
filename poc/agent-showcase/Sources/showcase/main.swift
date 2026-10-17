import ApplicationServices
import Foundation

// Usage: swift run showcase [script.json] [--dry] [--mode ghost|drive] [--recorder builtin|external|none]
//   --dry       resolve every target and print the steps; touches nothing
//   --mode      ghost (default): Pubbles draws the pointer, your mouse and keyboard stay free
//               drive: the real cursor moves, so hands off (moving the mouse aborts)
//   --recorder  builtin (default): record just the page window to ~/Movies/Pubbles
//               external: you run your own recorder (start it before pressing Return)
//               none: no recording
//
// The take waits for Return (shown in a bubble), counts down, then plays. Esc stops it any time,
// and stops the recording too.

let args = CommandLine.arguments
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let dry = args.contains("--dry")
let mode = option("--mode") ?? "ghost"
let recorderMode = option("--recorder") ?? "builtin"
guard ["ghost", "drive"].contains(mode), ["builtin", "external", "none"].contains(recorderMode) else {
    print("usage: showcase [script.json] [--dry] [--mode ghost|drive] [--recorder builtin|external|none]")
    exit(2)
}

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let scriptPath = args.dropFirst().first { $0.hasSuffix(".json") } ?? packageDir.appendingPathComponent("scripts/pubbles-app.json").path

var exitCode: Int32 = 0
let input = Input()
input.dry = dry
let motion = Motion(input: input)
let pubbles = Pubbles(dry: dry)
let recorder = Recorder()

/// Bubble at the start point: "press return to start", then a 3-2-1 countdown.
func readyPrompt() throws {
    try pubbles.send("show")
    try pubbles.send("type", ["text": "press return to start"])
    try pubbles.send("newline")
    try pubbles.send("type", ["text": recorderMode == "external" ? "start your recorder first" : "esc stops the take"])
    keyWatcher.resetGo()
    while !keyWatcher.goRequested {
        if keyWatcher.stopRequested { throw DriverError.aborted("cancelled before the take started") }
        Thread.sleep(forTimeInterval: 0.05)
    }
    for n in [3, 2, 1] {
        try pubbles.send("clear")
        try pubbles.send("type", ["text": "starting in \(n)"])
        Thread.sleep(forTimeInterval: 1)
        if keyWatcher.stopRequested { throw DriverError.aborted("cancelled during the countdown") }
    }
    try pubbles.send("dismissAll")
    Thread.sleep(forTimeInterval: 0.5) // let it fade before recording starts
}

do {
    let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: scriptPath)))
    let size = script.viewport ?? [1440, 900]
    let browser = Browser(port: 9334, url: script.url, viewport: CGSize(width: size[0], height: size[1]),
                          profileDir: packageDir.appendingPathComponent(".chrome-profile"))
    log("script \(scriptPath) — \(script.steps.count) steps, \(mode) mode, recorder: \(recorderMode)")
    for w in pubbles.warnings() { log("⚠︎ \(w)") }

    if !dry {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        guard trusted else {
            throw DriverError.preflight("this terminal needs Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }
        guard Pubbles.isRunning() else { throw DriverError.preflight("Pubbles isn't running") }
        try pubbles.send("dismissAll") // known starting state; also checks the control channel answers
        try keyWatcher.start()
    }

    try browser.launchOrAttach()
    try browser.fitWindow()
    try browser.load()
    browser.activate()
    input.sleep(0.5)

    let ghost = Ghost(pubbles: pubbles, browser: browser)
    let start = browser.vp(size[0] * 0.5, size[1] * 0.55)
    if mode == "ghost" {
        input.sink = ghost
        input.warp(start) // the ghost pointer appears here; the real mouse isn't touched
    } else {
        // Real cursor: click once on empty page so it has keyboard focus, then park at the start.
        let focus = script.focusAt ?? [40, size[1] - 40]
        input.warp(browser.vp(focus[0], focus[1]))
        input.click()
        input.sleep(0.3)
        input.warp(start)
    }

    if !dry {
        try readyPrompt()
        if recorderMode == "builtin" {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Pubbles")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = URL(fileURLWithPath: scriptPath).deletingPathExtension().lastPathComponent
            try recorder.start(rect: browser.screenRect, to: dir.appendingPathComponent("\(name)-\(stamp).mov").path,
                               showCursor: mode == "drive")
        }
    }

    let started = Date()
    try Player(input: input, motion: motion, browser: browser, pubbles: pubbles).run(script.steps)
    log(String(format: "✓ take finished in %.1fs", Date().timeIntervalSince(started)))
} catch {
    log("✗ \(error)")
    exitCode = 1
}

input.releaseAll()
recorder.stop() // also on Esc/abort, so a partial take is still saved
if !dry {
    _ = try? pubbles.send("dismissAll")
    _ = try? pubbles.send("ghostOff")
}
exit(exitCode)
