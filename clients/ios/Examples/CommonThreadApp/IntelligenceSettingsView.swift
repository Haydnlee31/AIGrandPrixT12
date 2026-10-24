import SwiftUI

struct IntelligenceSettingsView: View {
    @State private var origin = ""
    @State private var token = ""
    @State private var configured = false
    @State private var testing = false
    @State private var status: String?
    @State private var testResult: CaptureIntelligenceResult?
    var body: some View {
        Form {
            Section {
                Label(configured ? "Shopping intelligence is connected" : "Connect shopping intelligence", systemImage: configured ? "checkmark.shield.fill" : "sparkles")
                    .foregroundStyle(configured ? .green : .primary)
                Text("Get product-aware note suggestions and a detailed breakdown of each find. Saving works even when AI is unavailable.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Connection") {
                TextField("HTTPS service address", text: $origin).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(configured ? "New service access token (optional)" : "Service access token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("This is the app’s protected service connection. The OpenAI API key stays on the server.").font(.caption).foregroundStyle(.secondary)
                Button("Save connection") { saveConnection() }.disabled(testing || origin.isEmpty)
            }
            if configured {
                Section {
                    Button { Task { await checkConnection() } } label: {
                        if testing { ProgressView("Checking with OpenAI…") }
                        else { Label("Check connection", systemImage: "checkmark.icloud") }
                    }.disabled(testing)
                    Text("Runs a small request about a sample digital watch. It doesn’t use your library.").font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect intelligence", role: .destructive) {
                        do { try CaptureIntelligence.disconnect(); configured = false; token = ""; testResult = nil; status = "Disconnected. Local saving still works." }
                        catch { status = error.localizedDescription }
                    }.disabled(testing)
                }
            }
            if let status { Section { Text(status).font(.subheadline).textSelection(.enabled) } }
            if let result = testResult {
                Section("Live response") {
                    Text(result.productName ?? "Context reviewed").font(.headline)
                    ForEach(result.prompts) { Text($0.text) }
                }
            }
            Section("Your content") {
                Text("While connected, selected photos, supported audio and product context are sent to OpenAI for analysis. Your library remains on this iPhone. Multimodal drafts are deleted after completion or cancellation when reachable; interrupted cleanup can leave temporary server data. OpenAI response storage is disabled.")
                Text("Price watches are separate: the service stores the exact product link, target and observed prices for watches you create. Stop tracking a product in Radar to remove that watch and its history.")
                Text("A development relay works while its host and secure tunnel are running. Your team can replace the service address with a permanent deployment.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Shopping intelligence").navigationBarTitleDisplayMode(.inline)
        .task {
            if let configuration = try? CaptureIntelligence.configuration() {
                origin = configuration.baseURL.absoluteString; configured = true
            }
        }
    }
    private func saveConnection() {
        do {
            guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CaptureIntelligence.Failure.configuration }
            let old = try CaptureIntelligence.configuration()
            let supplied = token.trimmingCharacters(in: .whitespacesAndNewlines)
            // A new origin must be explicitly paired with its token; never forward an old credential elsewhere.
            guard !supplied.isEmpty || old?.baseURL == url else { throw CaptureIntelligence.Failure.configuration }
            try CaptureIntelligence.configure(.init(baseURL: url, accessToken: supplied.isEmpty ? old?.accessToken ?? "" : supplied,
                multimodalURL: old?.baseURL == url ? old?.multimodalURL : nil, multimodalToken: old?.baseURL == url ? old?.multimodalToken : nil))
            token = ""; configured = true; status = "Connection saved securely."
        } catch { status = error.localizedDescription }
    }
    @MainActor private func checkConnection() async {
        testing = true; status = nil; testResult = nil
        defer { testing = false }
        do {
            testResult = try await CaptureIntelligence.analyze(url: nil, title: "Digital wristwatch", text: "A silver digital wristwatch with a rectangular face and metal bracelet. Brand is not visible.", note: "", imageData: nil)
            status = "Live OpenAI request succeeded."
        } catch { status = error.localizedDescription }
    }
}
