import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class DictationController: ObservableObject {
    enum Phase {
        case idle
        case starting
        case recording
        case stopping
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private let speechRecognizer = SFSpeechRecognizer(locale: .current)
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var tapInstalled = false

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        transcript = ""
        errorMessage = nil

        guard await requestSpeechAuthorization() else {
            fail(
                "Speech recognition access is required. Enable it in System Settings > "
                    + "Privacy & Security > Speech Recognition."
            )
            return
        }
        guard phase == .starting else { return }

        guard await requestMicrophoneAuthorization() else {
            fail(
                "Microphone access is required. Enable it in System Settings > "
                    + "Privacy & Security > Microphone."
            )
            return
        }
        guard phase == .starting else { return }

        do {
            try beginRecognition()
        } catch {
            fail("Dictation could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        switch phase {
        case .idle, .stopping:
            return
        case .starting:
            cancel()
        case .recording:
            phase = .stopping
            audioEngine?.stop()
            removeTap()
            recognitionRequest?.endAudio()
            recognitionTask?.finish()
        }
    }

    func cancel() {
        sessionID = nil
        tearDown(cancelTask: true)
    }

    private func beginRecognition() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.noAudioInput
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        let id = UUID()

        audioEngine = engine
        recognitionRequest = request
        sessionID = id

        Self.installAudioTap(on: inputNode, format: format, request: request)
        tapInstalled = true

        recognitionTask = Self.startRecognitionTask(with: speechRecognizer, request: request) { [weak self] text, isFinal, errorDescription in
            Task { @MainActor [weak self] in
                self?.receive(
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorDescription,
                    sessionID: id
                )
            }
        }

        engine.prepare()
        do {
            try engine.start()
            phase = .recording
        } catch {
            tearDown(cancelTask: true)
            throw error
        }
    }

    nonisolated private static func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
    }

    nonisolated private static func startRecognitionTask(
        with speechRecognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        speechRecognizer.recognitionTask(with: request) { result, error in
            handler(
                result?.bestTranscription.formattedString,
                result?.isFinal == true,
                error?.localizedDescription
            )
        }
    }

    private func receive(
        text: String?,
        isFinal: Bool,
        errorDescription: String?,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID else { return }

        if let text {
            transcript = text
        }

        if isFinal || errorDescription != nil {
            let shouldReportError = errorDescription != nil && phase == .recording
            tearDown(cancelTask: false)
            if shouldReportError, let errorDescription {
                errorMessage = "Dictation stopped: \(errorDescription)"
            }
        }
    }

    private func fail(_ message: String) {
        sessionID = nil
        tearDown(cancelTask: true)
        errorMessage = message
    }

    private func tearDown(cancelTask: Bool) {
        audioEngine?.stop()
        removeTap()
        recognitionRequest?.endAudio()
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        phase = .idle
    }

    private func removeTap() {
        guard tapInstalled, let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    nonisolated private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                let handler: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { status in
                    continuation.resume(returning: status)
                }
                SFSpeechRecognizer.requestAuthorization(handler)
            }
            return status == .authorized
        @unknown default:
            return false
        }
    }

    nonisolated private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    private enum DictationError: LocalizedError {
        case recognizerUnavailable
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                "Speech recognition is currently unavailable."
            case .noAudioInput:
                "No microphone input is available."
            }
        }
    }
}
