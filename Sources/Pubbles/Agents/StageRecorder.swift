import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records exactly what a take shows: the stage window (or an app script's windows) plus Pubbles'
/// overlay (ghost pointer, bubbles, doodles), cropped to the take's region. Other windows aren't in
/// the capture, so the user can keep working and even overlap it. Needs Screen Recording permission.
final class StageRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "app.pubbles.stage-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private(set) var startedAt: Date?

    init(url: URL) {
        self.url = url
    }

    /// A window a take shows: its owner and roughly where it is.
    typealias Shown = (pid: pid_t, frame: CGRect)

    /// What to capture: the given windows plus Pubbles' full-screen overlay, cropped to `region`.
    @MainActor
    private static func capture(region: CGRect, windows: [Shown]) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw TakeError.stage(code: "permission_missing:screen_recording", message:
                "Pubbles needs Screen Recording permission (Pubbles Settings, or System Settings → Privacy & Security → Screen Recording)")
        }
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) else {
            throw TakeError.stage(code: "stage_not_visible", message: "Couldn't find the display the take is on")
        }
        let bounds = CGDisplayBounds(display.displayID)
        let region = region.intersection(bounds)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let stageWindows = content.windows.filter { w in
            w.windowLayer == 0 && windows.contains { $0.pid == w.owningApplication?.processID && $0.frame.intersects(w.frame) }
        }
        let overlays = content.windows.filter {
            $0.owningApplication?.processID == ourPID && $0.frame.width >= bounds.width && $0.frame.height >= bounds.height
        }
        guard !stageWindows.isEmpty else {
            throw TakeError.stage(code: "stage_not_visible", message: "Couldn't find the take's windows to capture")
        }
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.sourceRect = region.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        config.width = Int(region.width * scale) & ~1
        config.height = Int(region.height * scale) & ~1
        config.showsCursor = false // the ghost pointer is drawn by Pubbles
        return (SCContentFilter(display: display, including: stageWindows + overlays), config)
    }

    /// One frame of the take's region with Pubbles' overlay (bubbles, pins, doodles, ghost pointer).
    @MainActor
    static func snapshot(region: CGRect, windows: [Shown]) async throws -> CGImage {
        let (filter, config) = try await capture(region: region, windows: windows)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    func start(region: CGRect, windows: [Shown]) async throws {
        let (filter, config) = try await Self.capture(region: region, windows: windows)
        let width = config.width, height = config.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw TakeError.setup("Couldn't start writing the recording") }
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        startedAt = Date()
    }

    /// Stop and finish the file. Safe to call when nothing was started.
    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        queue.sync { input?.markAsFinished() }
        await writer?.finishWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer, let input else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }
}
