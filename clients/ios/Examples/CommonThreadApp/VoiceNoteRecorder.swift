import Foundation
import Observation
import AVFoundation

/// A short recording becomes editable text through the private OpenAI relay.
/// Temporary audio is removed at stop; retry audio lives only in memory.
@Observable @MainActor final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    var transcript = ""
    var isRecording = false
    var isTranscribing = false
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    var canRetry = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var audio: Data?
    @ObservationIgnored private var callback: (@MainActor (String) -> Void)?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var peakPower: Float = -160
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.cancel()
                self.errorMessage = "Recording was interrupted. Your note is unchanged. Tap the microphone to try again."
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    enum RecordingError: LocalizedError {
        case microphoneDenied, unavailable, noSpeech
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Allow it in iPhone Settings, or type your note."
            case .unavailable: "Couldn’t start the microphone. You can try again or type your note."
            case .noSpeech: "No clear speech was recorded. Tap the microphone and try again."
            }
        }
    }

    func start(onTranscript: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        guard !isRecording, !isTranscribing else { return }
        cancel()
        guard CaptureIntelligence.isConfigured else { throw OpenAIDictation.Failure.configuration }
        let runID = UUID(); sessionID = runID
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard sessionID == runID else { throw CancellationError() }
        guard allowed else { throw RecordingError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mynah-dictation-\(runID.uuidString).m4a")
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let capture = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            capture.delegate = self; capture.isMeteringEnabled = true
            guard capture.prepareToRecord(), capture.record(forDuration: 60) else { throw RecordingError.unavailable }
            recorder = capture; recordingURL = file; callback = onTranscript
            transcript = ""; elapsed = 0; peakPower = -160; errorMessage = nil; isRecording = true
            meterTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.sessionID == runID, self.isRecording, let capture = self.recorder else { return }
                    capture.updateMeters(); self.peakPower = max(self.peakPower, capture.peakPower(forChannel: 0))
                    self.elapsed = capture.currentTime
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecordingError.unavailable
        }
    }

    /// Explicit stop submits this recording once. Dismissal uses cancel instead.
    func stop() {
        guard isRecording, let capture = recorder, let file = recordingURL else { return }
        capture.updateMeters(); peakPower = max(peakPower, capture.peakPower(forChannel: 0))
        elapsed = max(elapsed, capture.currentTime)
        isRecording = false; meterTask?.cancel(); meterTask = nil
        capture.delegate = nil; capture.stop(); recorder = nil; recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { try? FileManager.default.removeItem(at: file) }
        guard elapsed >= 0.35, peakPower > -55 else { errorMessage = RecordingError.noSpeech.localizedDescription; return }
        do {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= OpenAIDictation.maximumBytes else { throw OpenAIDictation.Failure.tooLarge }
            audio = bytes; beginTranscription()
        } catch { errorMessage = error.localizedDescription }
    }

    func retry() { guard canRetry, !isRecording, !isTranscribing else { return }; beginTranscription() }

    func cancel() {
        sessionID = UUID()
        meterTask?.cancel(); meterTask = nil
        transcriptionTask?.cancel(); transcriptionTask = nil
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil; audio = nil; callback = nil
        let hadAudioSession = isRecording
        isRecording = false; isTranscribing = false; canRetry = false; errorMessage = nil
        if hadAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func beginTranscription() {
        guard let audio, !isTranscribing else { return }
        let runID = sessionID
        isTranscribing = true; canRetry = false; errorMessage = nil
        transcriptionTask = Task { @MainActor [weak self] in
            do {
                let text = try await OpenAIDictation.transcribe(audio)
                try Task.checkCancellation()
                guard let self, self.sessionID == runID else { return }
                self.transcript = text; self.audio = nil; self.isTranscribing = false
                self.callback?(text); self.callback = nil; self.transcriptionTask = nil
            } catch {
                guard let self, self.sessionID == runID, !Task.isCancelled else { return }
                self.isTranscribing = false; self.transcriptionTask = nil
                self.canRetry = (error as? OpenAIDictation.Failure) != .noSpeech
                if !self.canRetry { self.audio = nil }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recordingURL == url, self.isRecording else { return }
            if flag { self.stop() }
            else { self.cancel(); self.errorMessage = RecordingError.unavailable.localizedDescription }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recordingURL == url else { return }
            self.cancel(); self.errorMessage = RecordingError.unavailable.localizedDescription
        }
    }
}
