import SwiftUI

/// A single, skippable follow-up. Saving an answer closes this sheet; further
/// refinement happens only when the person deliberately taps a selected detail.
struct IntentRefinementSheet: View {
    let context: IntentRefinementContext
    let onSelect: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var result: IntentRefinementResult?
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label(context.selectedIntent, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.purple)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    if context.existingIntents.count >= 8 {
                        Text("You’ve kept eight details.").font(.title2.bold())
                        Text("You can edit or remove a detail whenever you like.").foregroundStyle(.secondary)
                    } else if loading {
                        HStack(spacing: 12) {
                            ProgressView().tint(.purple)
                            Text("Loading options…").font(.headline)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 26)
                    } else if let result {
                        Text(result.question).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 10) {
                            ForEach(Array(result.choices.enumerated()), id: \.element) { index, choice in
                                Button {
                                    saving = true
                                    Task { @MainActor in
                                        if await onSelect(choice) { dismiss() }
                                        else { errorMessage = "Couldn’t save that detail. You can try again or skip." }
                                        saving = false
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: ["sparkles", "heart.fill", "slider.horizontal.3"][index % 3])
                                            .font(.title3).foregroundStyle([Color.purple, .pink, .blue][index % 3])
                                            .frame(width: 36)
                                        Text(choice).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "plus.circle").foregroundStyle(.purple)
                                    }.foregroundStyle(.primary).padding(17)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 19))
                                }.buttonStyle(.plain).disabled(saving)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                        if result == nil { Button("Try again") { retry += 1 }.font(.headline).disabled(loading) }
                    }
                    if saving { ProgressView("Keeping your detail…") }
                }.padding(22)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Refine").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip for now") { dismiss() }.disabled(saving) } }
            .task(id: retry) {
                guard context.existingIntents.count < 8 else { loading = false; return }
                loading = true; errorMessage = nil
                defer { loading = false }
                do {
                    let response = try await CaptureIntelligence.refineIntent(context)
                    try Task.checkCancellation()
                    result = response
                } catch is CancellationError {} catch {
                    if !Task.isCancelled { errorMessage = "A follow-up isn’t available right now. Your selected detail is already kept." }
                }
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .interactiveDismissDisabled(saving)
    }
}

struct SelectedIntentChips: View {
    let values: [String]
    let onRefine: (String) -> Void
    let onRemove: (String) -> Void
    var onEdit: ((String) -> Void)? = nil
    var disabled = false
    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(values, id: \.self) { value in
                            Button { onRefine(value) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                                    Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                                }.foregroundStyle(.primary).padding(.horizontal, 13).padding(.vertical, 11)
                                    .frame(maxWidth: 260).background(.purple.opacity(0.09), in: Capsule())
                            }.buttonStyle(.plain).disabled(disabled)
                                .accessibilityLabel(value).accessibilityHint("Add more detail to this preference")
                                .contextMenu {
                                    Button("Add more detail", systemImage: "sparkles") { onRefine(value) }
                                    if let onEdit { Button("Edit", systemImage: "square.and.pencil") { onEdit(value) } }
                                    Button("Remove", systemImage: "minus.circle", role: .destructive) { onRemove(value) }
                                }
                        }
                    }
                }
            }
        }
    }
}
