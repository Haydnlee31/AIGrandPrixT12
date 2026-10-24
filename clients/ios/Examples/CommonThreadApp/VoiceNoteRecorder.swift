import SwiftUI
import AVFoundation
import UIKit

/// Records a bounded, local AAC file. Only the normal capture flow can upload it.
@MainActor final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    private var generation = UUID()
    @Published private(set) var elapsed = 0
    @Published var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var timer: Timer?
    private var interruption: NSObjectProtocol?
    private var completion: ((LocalCaptureAttachment) -> Void)?

    func start(onComplete: @escaping (LocalCaptureAttachment) -> Void) async {
        guard !isRecording, !isPreparing else { return }
        let request = UUID(); generation = request; isPreparing = true
        defer { if generation == request { isPreparing = false } }
        errorMessage = nil
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == request else { return }
        guard granted else { errorMessage = "Allow microphone access in Settings to record a voice note. You can still type your note."; return }
        guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let value = try AVAudioRecorder(url: destination, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            file = destination; recorder = value; completion = onComplete; elapsed = 0
            value.delegate = self
            guard value.record(forDuration: 60) else { throw RecordingError.failed }
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed = Int(self.recorder?.currentTime ?? 0)
                }
            }
            interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: session, queue: .main) { [weak self] notification in
                guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.stop() }
            }
        } catch { errorMessage = "The recording couldn’t start. Please try again."; cancel() }
    }
    func stop() { recorder?.stop() }
    func cancel() {
        generation = UUID(); isPreparing = false
        completion = nil
        recorder?.stop()
        cleanUp()
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finish(recorder, success: flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.finish(recorder, success: false) }
    }
    private func finish(_ source: AVAudioRecorder, success: Bool) {
        guard recorder === source, let file else { return }
        let callback = completion
        if success, let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= 4 * 1024 * 1024 {
            callback?(.init(filename: "Voice note.m4a", typeIdentifier: "com.apple.m4a-audio", data: data))
        } else if callback != nil { errorMessage = "The voice note couldn’t be saved. Please record it again." }
        cleanUp()
    }
    private func cleanUp() {
        timer?.invalidate(); timer = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }; interruption = nil
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        recorder = nil; completion = nil; isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    private enum RecordingError: Error { case failed }
}
