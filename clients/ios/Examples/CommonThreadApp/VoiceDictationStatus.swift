import SwiftUI

struct VoiceDictationStatus: View {
    let recorder: VoiceNoteRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.isTranscribing {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Transcribing with OpenAI…") }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictationTranscribing")
            } else if recorder.isRecording {
                Label("Recording · \(Int(recorder.elapsed))s / 60s", systemImage: "waveform")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.red)
            } else if recorder.errorMessage == nil {
                Text("Voice notes are transcribed by OpenAI.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = recorder.errorMessage {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                if recorder.canRetry { Button("Retry transcription", systemImage: "arrow.clockwise") { recorder.retry() }.font(.subheadline.bold()) }
            }
        }
    }
}
