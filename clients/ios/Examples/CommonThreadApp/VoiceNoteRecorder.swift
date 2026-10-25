import SwiftUI
import AVFoundation
import UIKit

/// The small seam allows lifecycle failures to be reproduced without replacing
/// AVAudioRecorder in the actual app or making a model/network request.
@MainActor protocol VoiceRecording: AnyObject {
    var currentTime: TimeInterval { get }
    var onFinished: ((Bool) -> Void)? { get set }
    var onError: (() -> Void)? { get set }
    func prepareToRecord() -> Bool
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}

@MainActor private final class NativeVoiceRecording: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    private let recorder: AVAudioRecorder
    var onFinished: ((Bool) -> Void)?
    var onError: (() -> Void)?
    var currentTime: TimeInterval { recorder.currentTime }
    init(url: URL, settings: [String: Any]) throws {
        recorder = try AVAudioRecorder(url: url, settings: settings)
        super.init()
        recorder.delegate = self
    }
    func prepareToRecord() -> Bool { recorder.prepareToRecord() }
    func record(forDuration duration: TimeInterval) -> Bool { recorder.record(forDuration: duration) }
    func stop() { recorder.stop() }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.onFinished?(flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.onError?() }
    }
}

/// Records a bounded local AAC file. Only the normal capture flow can upload it.
@MainActor final class VoiceNoteRecorder: ObservableObject {
    @MainActor struct Environment {
        var requestPermission: () async -> Bool
        var applicationState: () -> UIApplication.State
        var activateSession: () throws -> Void
        var deactivateSession: () -> Void
        var makeRecorder: (URL, [String: Any]) throws -> any VoiceRecording
        var foregroundWait: TimeInterval = 2
        static var live: Environment {
            Environment(requestPermission: {
                await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
            }, applicationState: { UIApplication.shared.applicationState }, activateSession: {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
            }, deactivateSession: {
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }, makeRecorder: { try NativeVoiceRecording(url: $0, settings: $1) })
        }
    }

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var elapsed = 0
    @Published var errorMessage: String?
    private let environment: Environment
    private var generation = UUID()
    private var recorder: (any VoiceRecording)?
    private var file: URL?
    private var timer: Timer?
    private var interruption: NSObjectProtocol?
    private var finalization: Task<Void, Never>?
    private var completion: ((LocalCaptureAttachment) -> Void)?
    private var activatedSession = false

    init(environment: Environment? = nil) { self.environment = environment ?? .live }

    func start(onComplete: @escaping (LocalCaptureAttachment) -> Void) async {
        guard !isRecording, !isPreparing, !isFinishing else { return }
        let request = UUID(); generation = request; isPreparing = true
        defer { if generation == request { isPreparing = false } }
        errorMessage = nil
        let granted = await environment.requestPermission()
        guard generation == request, !Task.isCancelled else { return }
        guard granted else {
            errorMessage = "Allow microphone access in Settings to record a voice note. You can still type your note."
            return
        }
        // iOS may invoke the grant callback before dismissing its permission
        // sheet. Wait for the foreground transition instead of silently losing the tap.
        let deadline = Date().addingTimeInterval(environment.foregroundWait)
        while environment.applicationState() != .active {
            guard generation == request, !Task.isCancelled else { return }
            guard environment.applicationState() != .background, Date() < deadline else {
                errorMessage = "Return to this screen and tap Record a voice note again."
                return
            }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        guard generation == request, !Task.isCancelled else { return }
        do {
            try environment.activateSession(); activatedSession = true
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            file = destination
            let value = try environment.makeRecorder(destination, Self.settings)
            recorder = value; completion = onComplete; elapsed = 0
            value.onFinished = { [weak self] success in self?.finish(request: request, success: success) }
            value.onError = { [weak self] in self?.finish(request: request, success: false) }
            interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.stop() }
            }
            guard value.prepareToRecord(), value.record(forDuration: 60) else { throw RecordingError.failed }
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == request, self.isRecording else { return }
                    self.elapsed = Int(self.recorder?.currentTime ?? 0)
                }
            }
        } catch {
            errorMessage = "The recording couldn’t start. Check your microphone connection and try again."
            cancel()
        }
    }

    /// An interruption does not guarantee an AVAudioRecorder finish callback.
    /// Stop closes the file; the explicit finalizer also covers that missing callback.
    func stop() {
        guard let recorder, !isFinishing else { return }
        isRecording = false; isFinishing = true
        recorder.stop()
        finish(request: generation, success: true)
    }

    func handleSceneChange(isActive: Bool, isBackground: Bool) {
        if isBackground && isPreparing { cancel(); return }
        if !isActive && isRecording { stop() }
    }

    func cancel() {
        generation = UUID(); isPreparing = false
        completion = nil
        recorder?.onFinished = nil; recorder?.onError = nil
        recorder?.stop()
        cleanUp()
    }

    private func finish(request: UUID, success: Bool) {
        guard generation == request, recorder != nil, let file else { return }
        guard success else {
            errorMessage = "The voice note couldn’t be saved. Please record it again."
            cleanUp(); return
        }
        isRecording = false; isFinishing = true
        guard finalization == nil else { return }
        finalization = Task { [weak self] in
            // Give the encoder time to close the AAC container after stop or an
            // interruption. A quick tap that produced only a header is not audio.
            for attempt in 0..<12 {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                do {
                    let data = try Self.validatedRecording(at: file)
                    guard self.generation == request, !Task.isCancelled else { return }
                    let callback = self.completion
                    self.cleanUp()
                    callback?(.init(filename: "Voice note.m4a", typeIdentifier: "com.apple.m4a-audio", data: data))
                    return
                } catch {
                    if attempt == 11 {
                        self.errorMessage = "The voice note was too short or couldn’t be read. Record for at least a moment and try again."
                        self.cleanUp(); return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    static func validatedRecording(at url: URL) throws -> Data {
        let source = try AVAudioFile(forReading: url)
        let rate = source.processingFormat.sampleRate
        guard rate > 0, source.length >= AVAudioFramePosition(rate * 0.25),
              Double(source.length) / rate <= 61 else { throw RecordingError.unreadable }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw RecordingError.unreadable }
        return data
    }

    private func cleanUp() {
        finalization?.cancel(); finalization = nil
        timer?.invalidate(); timer = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }; interruption = nil
        recorder?.onFinished = nil; recorder?.onError = nil
        recorder?.stop()
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        recorder = nil; completion = nil; isRecording = false; isFinishing = false
        if activatedSession { environment.deactivateSession(); activatedSession = false }
    }
    private enum RecordingError: Error { case failed, unreadable }
}
