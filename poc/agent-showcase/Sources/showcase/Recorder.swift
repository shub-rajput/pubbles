import CoreGraphics
import Foundation

/// Built-in recording: macOS `screencapture -v` of exactly the scripted window, so there's no area
/// to set up. Needs Screen Recording permission for the terminal.
final class Recorder {
    private var process: Process?
    private(set) var path: String?

    /// `showCursor`: include the real cursor (drive mode). Ghost mode leaves it out, since Pubbles
    /// draws the pointer itself.
    func start(rect: CGRect, to path: String, showCursor: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-v"] + (showCursor ? ["-C"] : []) + ["-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        self.path = path
        Thread.sleep(forTimeInterval: 1.2) // capture warm-up
        log("recording → \(path)")
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        // Writing to stdin ("type any character to stop") isn't picked up from a pipe; SIGINT stops
        // the capture right away and still finalizes the file.
        p.interrupt()
        p.waitUntilExit()
        process = nil
        log("recording saved → \(path ?? "?")")
    }
}
