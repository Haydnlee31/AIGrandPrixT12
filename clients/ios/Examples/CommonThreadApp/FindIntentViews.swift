import SwiftUI

/// Shared visual language for saved-find context and recommendation feedback.
struct FindIntentRow: View {
    let text: String
    var index: Int = 0
    var selected = false
    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: FindIntentAppearance.symbol(for: text, index: index))
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            Text(text).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3).foregroundStyle(selected ? tint : .secondary)
        }.padding(14)
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
            Text(text).font(.body.weight(.medium)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
    }
}

/// Contextual questions sit on the saved image. Selecting the accompanying response
/// records a preference; the question itself is never stored as the user's answer.
struct FindIntentOverlay: View {
    let prompts: [CaptureIntelligenceResult.Prompt]
    let selected: [String]
    var busy = false
    let onSelect: (String) -> Void
    var body: some View {
        if !prompts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("A little more you").font(.caption.bold()).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 5)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                            Button { onSelect(prompt.text) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    if let question = prompt.question, !question.isEmpty {
                                        Text(question).font(.subheadline.weight(.semibold)).lineLimit(3)
                                            .foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    }
                                    HStack(spacing: 10) {
                                        Image(systemName: FindIntentAppearance.symbol(for: prompt.text, index: index))
                                            .font(.title3).foregroundStyle(FindIntentAppearance.color(index))
                                        Text(prompt.text).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                            .lineLimit(3).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        Image(systemName: selected.contains(prompt.text) ? "checkmark.circle.fill" : "plus.circle.fill")
                                            .font(.title3).foregroundStyle(FindIntentAppearance.color(index))
                                    }
                                }.padding(14).frame(width: 260, alignment: .leading)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 21))
                                    .overlay { RoundedRectangle(cornerRadius: 21).strokeBorder(selected.contains(prompt.text) ? FindIntentAppearance.color(index) : Color.clear, lineWidth: 2) }
                            }.buttonStyle(.plain).disabled(busy)
                                .accessibilityValue(selected.contains(prompt.text) ? "Selected" : "Not selected")
                        }
                    }
                }
            }
        }
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
