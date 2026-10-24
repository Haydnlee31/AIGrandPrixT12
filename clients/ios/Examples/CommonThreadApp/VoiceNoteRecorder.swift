import Foundation
import Observation
import AVFoundation
import Speech

/// Optional on-device dictation. A note can always be typed without granting access.
@Observable @MainActor final class VoiceNoteRecorder {
    var transcript = ""
    var isRecording = false
    var errorMessage: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var sessionID = UUID()

    enum RecordingError: LocalizedError {
        case microphoneDenied, speechDenied, unavailable
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access is off. You can allow it in Settings, or type your note below."
            case .speechDenied: return "Speech recognition access is off. You can allow it in Settings, or type your note below."
            case .unavailable: return "On-device voice notes aren’t available on this device right now. You can still type your note."
            }
        }
    }

    func start(onTranscript: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        guard !isRecording else { return }
        errorMessage = nil
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        try Task.checkCancellation()
        guard microphoneAllowed else { throw RecordingError.microphoneDenied }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        try Task.checkCancellation()
        guard speechStatus == .authorized else { throw RecordingError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw RecordingError.unavailable
        }

        let runID = UUID()
        sessionID = runID
        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecordingError.unavailable
        }
        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.shouldReportPartialResults = true
        speechRequest.requiresOnDeviceRecognition = true
        request = speechRequest
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            speechRequest.append(buffer)
        }
        hasInputTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw RecordingError.unavailable
        }
        isRecording = true
        recognitionTask = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.sessionID == runID, self.isRecording else { return }
                if let text {
                    self.transcript = text
                    onTranscript(text)
                }
                if let errorText, self.isRecording {
                    self.errorMessage = "Voice note stopped: \(errorText). You can edit the words below."
                }
                if isFinal || errorText != nil { self.stop() }
            }
        }
    }

    func stop() {
        // Freeze the last delivered words before audio teardown can enqueue another callback.
        sessionID = UUID()
        isRecording = false
        engine.stop()
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
