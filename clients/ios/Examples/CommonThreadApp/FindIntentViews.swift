import SwiftUI

/// Shared visual language for saved-find context and recommendation feedback.
struct FindIntentRow: View {
    let text: String
    var index: Int = 0
    var selected = false
    var compact = false
    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: FindIntentAppearance.symbol(for: text, index: index))
                .font(.system(size: compact ? 17 : 22, weight: .semibold)).foregroundStyle(tint)
                .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            Text(text).font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold)).multilineTextAlignment(.leading)
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3).foregroundStyle(selected ? tint : .secondary)
        }.padding(compact ? 11 : 14)
            .background(selected ? tint.opacity(0.08) : NativeTheme.bg, in: RoundedRectangle(cornerRadius: 19))
            .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(tint.opacity(selected ? 0.35 : 0), lineWidth: 1.5) }
            .accessibilityElement(children: .combine)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityHint("Add or remove this detail from your preferences")
    }
    private var tint: Color { FindIntentAppearance.color(index) }
}

struct FindInsightRow: View {
    let text: String
    var index: Int = 0
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ["eye.fill", "sparkles", "bookmark.fill"][index % 3])
                .font(.system(size: 21, weight: .semibold)).foregroundStyle(FindIntentAppearance.color(index))
                .frame(width: 44, height: 44)
                .background(FindIntentAppearance.color(index).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            Text(text).font(.body.weight(.medium)).foregroundStyle(.primary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
    }
}

/// Swipe between questions without turning a question into a recorded preference.
struct FindIntentOverlay: View {
    let prompts: [CaptureIntelligenceResult.Prompt]
    let selected: [String]
    var busy = false
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var pageHeight: CGFloat = 96
    @State private var page = 0
    var body: some View {
        if !prompts.isEmpty {
            VStack(spacing: 2) {
                TabView(selection: $page) {
                    ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                        questionCard(prompt, index: index).padding(.horizontal, 3).padding(.vertical, 5).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: pageHeight)
                if prompts.count > 1 {
                    HStack(spacing: 0) {
                        ForEach(prompts.indices, id: \.self) { index in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { page = index }
                            } label: {
                                Capsule().fill(page == index ? Color.primary : Color.secondary.opacity(0.3))
                                    .frame(width: page == index ? 16 : 5, height: 5)
                                    .frame(width: 28, height: 24).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Question \(index + 1) of \(prompts.count)")
                                .accessibilityAddTraits(page == index ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 5)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .onChange(of: prompts.map(\.id)) { _, _ in page = min(page, max(0, prompts.count - 1)) }
            .accessibilityIdentifier("findQuestionCarousel")
        }
    }
    private func questionCard(_ prompt: CaptureIntelligenceResult.Prompt, index: Int) -> some View {
        let question = prompt.question.flatMap { $0.isEmpty ? nil : $0 } ?? prompt.text
        let tint = FindIntentAppearance.color(index)
        return Button(action: onOpen) {
            HStack(spacing: 11) {
                Image(systemName: FindIntentAppearance.symbol(for: prompt.text, index: index))
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 36, height: 36).background(tint.opacity(0.12), in: Circle())
                Text(question).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading).lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected.contains(prompt.text) ? "checkmark.circle.fill" : "arrow.up.right")
                    .font(.caption.bold()).foregroundStyle(selected.contains(prompt.text) ? tint : .secondary)
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 21))
                .overlay { RoundedRectangle(cornerRadius: 21).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }.buttonStyle(.plain).disabled(busy)
            .accessibilityLabel(question)
            .accessibilityHint("Open personalization options in New Insights")
    }
}

/// Summary and evidence share one presentation so repeated observations appear once.
struct NewInsightHighlights: View {
    let summary: String
    let evidence: [String]
    let uncertainties: [String]
    private var fullSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var summaryHighlight: String {
        var firstSentence: String?
        fullSummary.enumerateSubstrings(in: fullSummary.startIndex..<fullSummary.endIndex, options: .bySentences) { sentence, _, _, stop in
            firstSentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        return firstSentence ?? fullSummary
    }
    private var observations: [String] {
        var values: [String] = []
        if !summaryHighlight.isEmpty { values.append(summaryHighlight) }
        for text in evidence.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty {
            // A title/caption transcription adds no visual insight. The original
            // remains available above, without repeating its wording as a finding.
            guard !isTitleOrCaptionEcho(text) else { continue }
            let key = normalized(text)
            let existingObservations = values + (fullSummary.isEmpty ? [] : [fullSummary])
            if !existingObservations.contains(where: {
                let existing = normalized($0)
                return existing == key || (min(existing.count, key.count) > 28 && (existing.contains(key) || key.contains(existing)))
            }) { values.append(text) }
        }
        return values
    }
    // A synthesis already combines the evidence. Keep its supporting observations
    // in Details so paraphrases never become duplicate main highlights.
    private var visibleCount: Int { fullSummary.isEmpty ? 2 : 1 }
    private var details: [String] {
        (fullSummary != summaryHighlight && !fullSummary.isEmpty ? [fullSummary] : []) + Array(observations.dropFirst(visibleCount))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(observations.prefix(visibleCount).enumerated()), id: \.offset) { index, text in
                FindInsightRow(text: text, index: index)
            }
            if !details.isEmpty || !uncertainties.isEmpty {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(details, id: \.self) { text in
                            Text(text).font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(uncertainties, id: \.self) { text in
                            Label(text, systemImage: "questionmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.top, 10)
                }.font(.subheadline.weight(.medium)).tint(.secondary)
            }
        }
    }
    private func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func isTitleOrCaptionEcho(_ text: String) -> Bool {
        normalized(text).range(of: "^(?:(?:the|saved|source|page|product|post|image|link) )*(?:title|caption)\\b", options: .regularExpression) != nil
    }
}

private enum FindIntentAppearance {
    static func color(_ index: Int) -> Color { [.blue, .purple, .orange, .pink, .teal, .indigo][abs(index) % 6] }
    static func symbol(for value: String, index: Int) -> String {
        let text = value.lowercased()
        if ["price", "budget", "cost", "afford"].contains(where: text.contains) { return "tag.fill" }
        if ["color", "colour", "look", "style", "vintage", "retro", "aesthetic"].contains(where: text.contains) { return "paintpalette.fill" }
        if ["size", "small", "large", "fit", "shape", "case", "width"].contains(where: text.contains) { return "ruler.fill" }
        if ["compare", "similar", "alternative"].contains(where: text.contains) { return "square.on.square" }
        if ["wear", "everyday", "daily", "comfort"].contains(where: text.contains) { return "heart.fill" }
        if ["quality", "durable", "material", "steel", "leather"].contains(where: text.contains) { return "checkmark.seal.fill" }
        return ["sparkles", "heart.fill", "lightbulb.fill"][abs(index) % 3]
    }
}
