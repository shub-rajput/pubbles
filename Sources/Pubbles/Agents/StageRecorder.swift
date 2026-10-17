import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records exactly the stage: the stage window plus Pubbles' overlay (ghost pointer, bubbles,
/// doodles), cropped to the page viewport. Other windows aren't in the capture, so the user can
/// keep working and even overlap the stage. Needs Screen Recording permission for Pubbles.
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

    @MainActor
    func start(stageRect: CGRect, stagePID: pid_t) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw TakeError.setup("Pubbles needs Screen Recording permission to record (System Settings → Privacy & Security → Screen Recording)")
        }
        let center = CGPoint(x: stageRect.midX, y: stageRect.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) else {
            throw TakeError.setup("Couldn't find the display the stage is on")
        }
        let bounds = CGDisplayBounds(display.displayID)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let stageWindows = content.windows.filter {
            $0.owningApplication?.processID == stagePID && $0.windowLayer == 0 && $0.frame.intersects(stageRect)
        }
        let overlays = content.windows.filter {
            $0.owningApplication?.processID == ourPID && $0.frame.width >= bounds.width && $0.frame.height >= bounds.height
        }
        guard !stageWindows.isEmpty else { throw TakeError.setup("Couldn't find the stage window to record") }

        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        let width = Int(stageRect.width * scale) & ~1, height = Int(stageRect.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.sourceRect = stageRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        config.width = width
        config.height = height
        config.showsCursor = false // the ghost pointer is drawn by Pubbles
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

        let stream = SCStream(filter: SCContentFilter(display: display, including: stageWindows + overlays),
                              configuration: config, delegate: nil)
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
