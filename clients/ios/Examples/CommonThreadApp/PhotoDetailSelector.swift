import SwiftUI

/// The user's lasso establishes a crop, never an inferred product preference.
struct PhotoDetailSelector: View {
    let attachment: DraftAttachment
    let productTitle: String
    let onConfirm: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var points: [CGPoint] = []
    @State private var selection: CGRect?
    @State private var crop: UIImage?
    @State private var suggestions: [String] = []
    @State private var preference = ""
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var requestTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Circle what you like.").font(.largeTitle.bold())
                    Text("Draw around a dial, strap, shape, or another detail. Only the selected area is analyzed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let image = attachment.preview {
                        GeometryReader { proxy in
                            let size = proxy.size
                            ZStack {
                                Image(uiImage: image).resizable().scaledToFit()
                                if let selection {
                                    Rectangle().fill(.purple.opacity(0.16))
                                        .overlay(Rectangle().stroke(.purple, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                                        .frame(width: selection.width * size.width, height: selection.height * size.height)
                                        .position(x: selection.midX * size.width, y: selection.midY * size.height)
                                }
                                Path { path in
                                    guard let first = points.first else { return }
                                    path.move(to: first)
                                    for point in points.dropFirst() { path.addLine(to: point) }
                                }.stroke(.purple, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            }.contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        if points.isEmpty { reset() }
                                        points.append(CGPoint(x: min(max(value.location.x, 0), size.width), y: min(max(value.location.y, 0), size.height)))
                                    }
                                    .onEnded { _ in finishSelection(size: size, image: image) })
                                .accessibilityLabel("Draw around the detail you like")
                        }.aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    if let crop {
                        HStack(spacing: 14) {
                            Image(uiImage: crop).resizable().scaledToFit().frame(width: 76, height: 76)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            Text("Your selected detail").font(.headline)
                            Spacer()
                            Button("Clear") { reset(); points = [] }
                        }
                        if busy { ProgressView("Looking at this detail…") }
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { preference = suggestion } label: {
                                Label(suggestion, systemImage: preference == suggestion ? "checkmark.circle.fill" : "sparkles")
                                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14).background(.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                            }.tint(.purple)
                        }
                        TextField("What do you like about this part?", text: $preference, axis: .vertical)
                            .lineLimit(2...4).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Try analysis again") { analyze(crop) }.disabled(busy)
                        }
                        Button("Add this detail") {
                            let value = preference.trimmingCharacters(in: .whitespacesAndNewlines)
                            if onConfirm(value) { dismiss() }
                            else { error = "You can keep up to eight details. Remove one in the capture screen first." }
                        }.buttonStyle(.borderedProminent).tint(.purple)
                            .disabled(preference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preference.count > 500)
                    } else {
                        Text("The original photo stays untouched.").font(.caption).foregroundStyle(.secondary)
                        if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("Highlight a detail").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onDisappear { requestTask?.cancel(); generation = UUID() }
        }
    }
    private func reset() {
        requestTask?.cancel(); generation = UUID(); selection = nil; crop = nil
        suggestions = []; preference = ""; error = nil; busy = false
    }
    private func finishSelection(size: CGSize, image: UIImage) {
        defer { points = [] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX - minX >= 18, maxY - minY >= 18, let cg = image.cgImage else {
            error = "Draw a larger circle around the detail."; return
        }
        let rect = CGRect(x: minX / size.width, y: minY / size.height,
                          width: (maxX - minX) / size.width, height: (maxY - minY) / size.height)
        let pixels = CGRect(x: rect.minX * CGFloat(cg.width), y: rect.minY * CGFloat(cg.height),
                            width: rect.width * CGFloat(cg.width), height: rect.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: pixels) else { error = "Try selecting this detail again."; return }
        let result = UIImage(cgImage: cropped)
        selection = rect; crop = result; analyze(result)
    }
    private func analyze(_ image: UIImage) {
        requestTask?.cancel()
        let token = UUID(); generation = token; busy = true; error = nil
        requestTask = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                let result = try await CaptureIntelligence.analyze(url: nil, title: "Selected detail of \(productTitle)",
                    text: "This image is a user-selected crop of a product. Describe only the visible part and its visible attributes. Suggest short first-person shopping preferences for that part, for example I like the silver dial. Do not assume the user wants the entire product or infer unseen brands or features.",
                    note: "The user is exploring this region; no preference is confirmed yet.", imageData: data, preferCapturedContent: true)
                try Task.checkCancellation()
                guard generation == token else { return }
                var seen = Set<String>()
                suggestions = Array(result.prompts.map(\.text).filter { seen.insert($0).inserted }.prefix(3))
                if suggestions.isEmpty { error = "No clear detail found. You can describe it below or select a larger area." }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = "Couldn’t analyze this detail. Try again or describe what you like below."
            }
        }
    }
}
