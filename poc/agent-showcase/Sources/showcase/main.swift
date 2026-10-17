import ApplicationServices
import Foundation

// Usage: swift run showcase [script.json] [--dry] [--countdown 5]
//   --dry        resolve every target and print the steps; never touches the mouse or keyboard
//   --countdown  seconds to wait after the page is ready (start your screen recorder then)
//
// Stop a take any time by moving the mouse yourself.

let args = CommandLine.arguments
let dry = args.contains("--dry")
let countdown = args.firstIndex(of: "--countdown").flatMap { Int(args[$0 + 1]) } ?? 5

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let scriptPath = args.dropFirst().first { $0.hasSuffix(".json") } ?? packageDir.appendingPathComponent("scripts/pubbles-app.json").path

var exitCode: Int32 = 0
let input = Input()
input.dry = dry
let motion = Motion(input: input)

do {
    let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: scriptPath)))
    let size = script.viewport ?? [1440, 900]
    let browser = Browser(port: 9334, url: script.url, viewport: CGSize(width: size[0], height: size[1]),
                          profileDir: packageDir.appendingPathComponent(".chrome-profile"))
    let pubbles = Pubbles(dry: dry)
    log("script \(scriptPath) — \(script.steps.count) steps")
    for w in pubbles.warnings() { log("⚠︎ \(w)") }

    if !dry {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        guard trusted else {
            throw DriverError.preflight("this terminal needs Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }
        guard Pubbles.isRunning() else { throw DriverError.preflight("Pubbles isn't running") }
        try pubbles.send("dismissAll") // known starting state; also checks the control channel answers
    }

    try browser.launchOrAttach()
    try browser.fitWindow()
    try browser.load()

    browser.activate()
    input.sleep(0.5)
    let focus = script.focusAt ?? [40, size[1] - 40]
    input.warp(browser.vp(focus[0], focus[1]))
    input.click()
    input.sleep(0.3)

    if !dry && countdown > 0 {
        for s in stride(from: countdown, to: 0, by: -1) {
            log("starting in \(s)… (start your recorder now; move the mouse to abort)")
            input.sleep(1)
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
exit(exitCode)
