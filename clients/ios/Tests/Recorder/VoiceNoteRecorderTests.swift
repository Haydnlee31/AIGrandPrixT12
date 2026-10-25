import XCTest
import AVFoundation
import UIKit
import CommonThreadKit
@testable import CommonThread

/// These tests exercise the production state machine. Only the lifecycle cases
/// inject an engine; testNativeAVAudioRecorderWritesDecodableAAC uses the real mic.
@MainActor final class VoiceNoteRecorderTests: XCTestCase {
    func testGrantWhileInactiveWaitsForForegroundAndStartsOnFirstTap() async throws {
        let rig = RecordingRig()
        rig.applicationState = .inactive
        let recorder = rig.recorder()
        let start = Task { await recorder.start { _ in } }
        await eventually { rig.permissionRequests == 1 }
        recorder.handleSceneChange(isActive: false, isBackground: false)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(recorder.isPreparing)
        XCTAssertEqual(rig.activations, 0)
        rig.applicationState = .active
        await start.value
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(recorder.isPreparing)
        XCTAssertEqual(rig.activations, 1)
        XCTAssertEqual(rig.engine?.recordCalls, 1)
        recorder.cancel()
    }

    func testCancelDuringPermissionIgnoresLateGrant() async {
        let rig = RecordingRig()
        var grant: CheckedContinuation<Bool, Never>?
        var environment = rig.environment()
        environment.requestPermission = { await withCheckedContinuation { grant = $0 } }
        let recorder = VoiceNoteRecorder(environment: environment)
        let start = Task { await recorder.start { _ in XCTFail("Cancelled recording must not attach") } }
        await eventually { grant != nil }
        recorder.cancel()
        grant?.resume(returning: true)
        await start.value
        XCTAssertEqual(rig.activations, 0)
        XCTAssertFalse(recorder.isPreparing)
        XCTAssertFalse(recorder.isRecording)
    }

    func testBackgroundDuringPermissionCancelsButInactiveDoesNot() async {
        let rig = RecordingRig()
        var grant: CheckedContinuation<Bool, Never>?
        var environment = rig.environment()
        environment.requestPermission = { await withCheckedContinuation { grant = $0 } }
        let recorder = VoiceNoteRecorder(environment: environment)
        let start = Task { await recorder.start { _ in XCTFail("Background request must not attach") } }
        await eventually { grant != nil }
        recorder.handleSceneChange(isActive: false, isBackground: false)
        XCTAssertTrue(recorder.isPreparing)
        recorder.handleSceneChange(isActive: false, isBackground: true)
        grant?.resume(returning: true)
        await start.value
        XCTAssertEqual(rig.activations, 0)
        XCTAssertFalse(recorder.isPreparing)
    }

    func testRepeatedTapWhilePreparingMakesOnePermissionRequest() async {
        let rig = RecordingRig()
        rig.applicationState = .inactive
        let recorder = rig.recorder()
        let start = Task { await recorder.start { _ in } }
        await eventually { rig.permissionRequests == 1 }
        await recorder.start { _ in XCTFail("Second tap replaced first completion") }
        XCTAssertEqual(rig.permissionRequests, 1)
        rig.applicationState = .active
        await start.value
        XCTAssertEqual(rig.activations, 1)
        recorder.cancel()
    }

    func testDeniedPermissionExplainsRecoveryWithoutOpeningSession() async {
        let rig = RecordingRig()
        var environment = rig.environment()
        environment.requestPermission = { false }
        let recorder = VoiceNoteRecorder(environment: environment)
        await recorder.start { _ in XCTFail("Denied microphone must not attach") }
        XCTAssertTrue(recorder.errorMessage?.contains("Settings") == true)
        XCTAssertFalse(recorder.isPreparing)
        XCTAssertEqual(rig.activations, 0)
    }

    func testForegroundTimeoutShowsErrorInsteadOfSilentlyDroppingTap() async {
        let rig = RecordingRig()
        rig.applicationState = .inactive
        var environment = rig.environment()
        environment.foregroundWait = 0.05
        let recorder = VoiceNoteRecorder(environment: environment)
        await recorder.start { _ in XCTFail("Inactive app must not attach") }
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertFalse(recorder.isPreparing)
        XCTAssertEqual(rig.activations, 0)
    }

    func testInterruptionFinalizesWithoutDelegateCallbackExactlyOnce() async throws {
        let rig = RecordingRig()
        let recorder = rig.recorder()
        var attachments: [LocalCaptureAttachment] = []
        await recorder.start { attachments.append($0) }
        let lateCallback = try XCTUnwrap(rig.engine?.onFinished)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await eventually { attachments.count == 1 }
        lateCallback(true)
        recorder.stop()
        XCTAssertEqual(attachments.count, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isFinishing)
        XCTAssertEqual(rig.deactivations, 1)
        XCTAssertEqual(attachments.first?.typeIdentifier, "com.apple.m4a-audio")
        XCTAssertFalse(try XCTUnwrap(attachments.first?.data).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(rig.engine?.url.path)))
    }

    func testStopBlocksNewRecordingUntilContainerIsFinalized() async {
        let rig = RecordingRig()
        let recorder = rig.recorder()
        var completed = 0
        await recorder.start { _ in completed += 1 }
        recorder.stop()
        XCTAssertTrue(recorder.isFinishing)
        await recorder.start { _ in XCTFail("Cannot replace a finishing recording") }
        await eventually { completed == 1 }
        XCTAssertEqual(rig.activations, 1)
        XCTAssertFalse(recorder.isFinishing)
    }

    func testHeaderOnlyRecordingIsRejectedAndStateRecovers() async {
        let rig = RecordingRig()
        rig.headerOnly = true
        let recorder = rig.recorder()
        await recorder.start { _ in XCTFail("An AAC header is not recorded audio") }
        recorder.stop()
        await eventually { !recorder.isFinishing }
        XCTAssertTrue(recorder.errorMessage?.contains("too short") == true)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(rig.deactivations, 1)
    }

    func testCancelDuringFinalizationCannotAttach() async {
        let rig = RecordingRig()
        let recorder = rig.recorder()
        await recorder.start { _ in XCTFail("Discarded recording must not attach") }
        recorder.stop()
        recorder.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(recorder.isFinishing)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(rig.deactivations, 1)
    }

    func testNativeAVAudioRecorderWritesDecodableAACAndDeliversTranscriptProgress() async throws {
        // CI pre-grants the real app microphone with simctl. No injected engine
        // or permission closure is used here; simulator input may be silence.
        let recorder = VoiceNoteRecorder()
        var result: LocalCaptureAttachment?
        await recorder.start { result = $0 }
        XCTAssertTrue(recorder.isRecording, recorder.errorMessage ?? "Native recorder failed to start")
        guard recorder.isRecording else { return }
        try await Task.sleep(for: .milliseconds(1300))
        recorder.stop()
        await eventually(timeout: 5) { result != nil || !recorder.isFinishing }
        let attachment = try XCTUnwrap(result, recorder.errorMessage ?? "Native recorder did not finish")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isFinishing)
        let output = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("microphone-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent("native-recorder.m4a")
        try attachment.data.write(to: destination)
        let audio = try AVAudioFile(forReading: destination)
        XCTAssertEqual(audio.fileFormat.sampleRate, 24_000, accuracy: 1)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(audio.length, 6_000)
        let frames = AVAudioFrameCount(min(audio.length, 24_000))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames))
        try audio.read(into: buffer, frameCount: frames)
        XCTAssertGreaterThan(buffer.frameLength, 0, "AAC must decode to actual audio frames")
        let evidence: [String: Any] = ["status": "passed", "engine": "AVAudioRecorder",
            "sample_rate": audio.fileFormat.sampleRate, "channels": audio.fileFormat.channelCount,
            "frames": audio.length, "bytes": attachment.data.count,
            "duration": Double(audio.length) / audio.fileFormat.sampleRate,
            "scope": "Real simulator recording engine, permissions, stop, AAC decode; does not prove a physical microphone or audible speech"]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-recorder.json"))
        let artifact = XCTAttachment(data: attachment.data, uniformTypeIdentifier: "com.apple.m4a-audio")
        artifact.name = "Real simulator AVAudioRecorder AAC (may be silent)"
        artifact.lifetime = .keepAlways
        add(artifact)
        try await verifyTranscriptProgress(using: attachment)
    }

    private func verifyTranscriptProgress(using attachment: LocalCaptureAttachment) async throws {
        // The recorded bytes and production iOS SDK/helper are real. Only HTTP
        // is a controlled fixture, so this does not claim speech recognition.
        let fixture = NativeTranscriptFixture(expectedAudio: attachment.data)
        NativeTranscriptProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeTranscriptProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); NativeTranscriptProtocol.fixture = nil }
        let origin = try XCTUnwrap(URL(string: "https://microphone-fixture.example.org"))
        let client = try CommonThreadClient(baseURL: origin, session: session) { "native-fixture-user" }
        let progress = NativeTranscriptProgress()
        let result = try await MultimodalDraftAnalysis.analyze(origin: origin, token: "unused",
            title: "Recorded voice", text: "", note: "", url: nil, images: [],
            audio: .init(data: attachment.data, filename: attachment.filename), client: client,
            onTranscript: { text in await progress.record(text, beforeReady: fixture.isStillAnalyzing) })
        let values = await progress.snapshot()
        XCTAssertEqual(values.texts, [NativeTranscriptFixture.transcript])
        XCTAssertTrue(values.beforeReady, "Transcript must reach native UI callback before product analysis completes")
        XCTAssertEqual(result.transcript, NativeTranscriptFixture.transcript)
        XCTAssertEqual(result.productName, "Digital watch")
        XCTAssertTrue(fixture.uploadMatched, "The exact real recorder AAC must survive SDK base64 upload")
        await eventually { fixture.wasDeleted }
    }

    private func eventually(timeout: TimeInterval = 3, file: StaticString = #filePath,
                            line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for recorder state", file: file, line: line)
    }
}

@MainActor private final class RecordingRig {
    var applicationState: UIApplication.State = .active
    var permissionRequests = 0
    var activations = 0
    var deactivations = 0
    var headerOnly = false
    var engine: FixtureVoiceRecording?
    func recorder() -> VoiceNoteRecorder { VoiceNoteRecorder(environment: environment()) }
    func environment() -> VoiceNoteRecorder.Environment {
        .init(requestPermission: { self.permissionRequests += 1; return true },
            applicationState: { self.applicationState },
            activateSession: { self.activations += 1 },
            deactivateSession: { self.deactivations += 1 },
            makeRecorder: { url, settings in
                let engine = FixtureVoiceRecording(url: url, settings: settings, headerOnly: self.headerOnly)
                self.engine = engine
                return engine
            })
    }
}

/// Deliberately never calls onFinished on stop, reproducing iOS interruptions.
/// Its audio is a synthesized fixture, separate from the native engine test.
@MainActor private final class FixtureVoiceRecording: VoiceRecording {
    let url: URL
    let settings: [String: Any]
    let headerOnly: Bool
    var recordCalls = 0
    var currentTime: TimeInterval { 1 }
    var onFinished: ((Bool) -> Void)?
    var onError: (() -> Void)?
    init(url: URL, settings: [String: Any], headerOnly: Bool) {
        self.url = url; self.settings = settings; self.headerOnly = headerOnly
    }
    func prepareToRecord() -> Bool { true }
    func record(forDuration duration: TimeInterval) -> Bool { recordCalls += 1; return true }
    func stop() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            if headerOnly { try Data("ftypM4A".utf8).write(to: url); return }
            let output = try AVAudioFile(forWriting: url, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 24_000))
            buffer.frameLength = 24_000
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<24_000 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 24_000) * 0.05) }
            try output.write(from: buffer)
        } catch { XCTFail("Could not construct deterministic AAC test fixture: \(error)") }
    }
}
