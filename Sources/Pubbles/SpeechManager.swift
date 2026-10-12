import Foundation
import Speech
import AVFoundation

// SpeechManager is intentionally NOT @MainActor.
// If it were @MainActor, Swift 6 would inject isolation-check thunks on every
// @escaping closure defined inside the class — including the AVAudioEngine tap
// block, which AVFAudio calls from its private realtime thread. That thunk
// would call _dispatch_assert_queue_fail and crash immediately.
//
// Instead we leave the class non-isolated and manually dispatch to the main
// thread wherever we need to touch UI state (onResult, onError, session restarts).
class SpeechManager: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    // Only mutated on the main thread (callers are @MainActor).
    private(set) var isListening = false

    /// Called on the main thread with (fullTranscriptionSoFar, isFinal).
    var onResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// Called on the main thread with a normalized input level in 0...1 for UI metering.
    var onLevel: ((Float) -> Void)?

    func startListening() {
        guard !isListening else { return }
        isListening = true
        startSession()
    }

    func stopListening() {
        isListening = false
        tearDownSession()
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }

    /// Computes an RMS-based input level from a mic buffer, mapped to roughly 0...1.
    /// Runs on AVFAudio's realtime thread — keep it allocation-free and cheap.
    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        // Speech RMS sits around 0.02–0.2; scale up and clamp so normal talking fills the range.
        return min(1, rms * 8)
    }

    private func startSession() {
        guard let recognizer, recognizer.isAvailable else { return }

        let engine = AVAudioEngine()
        audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeechRecognitionTask callbacks may arrive on a background thread.
            // Extract Sendable values before hopping to main so Swift 6 doesn't
            // complain about sending a non-Sendable SFSpeechRecognitionResult across actors.
            let transcription = result.map { ($0.bestTranscription.formattedString, $0.isFinal) }
            let nsError = error.map { $0 as NSError }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if let (text, isFinal) = transcription {
                    self.onResult?(text, isFinal)
                    if isFinal { self.restartSessionIfListening() }
                }

                if let nsError {
                    // kAFAssistantErrorDomain 1110 = "No speech detected" — not a real error
                    let isSilence = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                    if isSilence {
                        self.restartSessionIfListening()
                    } else {
                        self.onError?(nsError)
                    }
                }
            }
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // This closure is called on AVFAudio's realtime thread.
        // Because SpeechManager is non-isolated, Swift 6 does NOT wrap this in
        // a @MainActor thunk — so it runs safely on the audio thread.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self, let level = SpeechManager.normalizedLevel(of: buffer) else { return }
            DispatchQueue.main.async { self.onLevel?(level) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
                self?.tearDownSession()
            }
        }
    }

    private func restartSessionIfListening() {
        guard isListening else { return }
        tearDownSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isListening else { return }
            self.startSession()
        }
    }

    private func tearDownSession() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
    }

    /// Checks current permission status without prompting.
    static func currentPermissionsGranted() -> Bool {
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return speech && mic
    }

    /// True when either permission was previously denied (system won't re-prompt).
    static func permissionsPreviouslyDenied() -> Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        return speech == .denied || speech == .restricted || mic == .denied || mic == .restricted
    }

    /// Returns the System Settings URL for whichever denied permission to fix first.
    static func deniedSettingsURL() -> URL {
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .denied || speech == .restricted {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    }

    /// Returns a short label for whichever denied permission to show in the pill.
    static func deniedPermissionLabel() -> String {
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .denied || speech == .restricted {
            return "Speech Recognition"
        }
        return "Microphone"
    }

    /// Requests mic + speech recognition permissions. Returns true only if both are granted.
    /// Uses Task.detached to avoid inheriting any actor isolation from the caller,
    /// which prevents Swift 6 runtime isolation checks from crashing when
    /// SFSpeechRecognizer calls back on a background thread.
    static func requestPermissions() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            guard speechStatus == .authorized else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        }.value
    }
}
