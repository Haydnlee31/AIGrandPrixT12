import SwiftUI
import CommonThreadKit

struct FindsAppRoot: View {
    @AppStorage("finds.onboarding.complete") private var completed = false
    var body: some View {
        Group {
            if completed { MymahFindsView() }
            else { FindsOnboardingView { completed = true } }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") { completed = false }
            if ProcessInfo.processInfo.arguments.contains("-skipOnboarding") { completed = true }
        }
    }
}

/// Practice stays in memory; only the existing capture form or share extension saves a find.
struct FindsOnboardingView: View {
    var isReplay = false
    var onComplete: () -> Void
    private enum Page { case welcome, sharing, example, saved }
    @State private var page = Page.welcome
    @State private var shareStep = 0
    @State private var showingCapture = false
    @State private var savedFind: SavedItem?
    @State private var savedID: String?
    @State private var loadingSave = false
    @State private var saveError: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private let shareTitles = ["Share a product", "Choose Mynah Finds", "Keep what matters"]
    private let shareDetails = [
        "On a shop page or photo, tap Share. In Instagram, tap the paper plane, then Share to…",
        "Tap the Mynah bird in the app row. If it’s missing, swipe to More, then Edit to add Mynah Finds to Favorites.",
        "Add an optional note about the style, fit or budget you have in mind. Tap Save find, then return to Mynah Finds."
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if page != .welcome && page != .saved {
                    Button { move(to: .welcome) } label: {
                        Image(systemName: "chevron.left").font(.body.bold()).frame(width: 44, height: 44)
                    }.accessibilityLabel("Back to welcome")
                }
                FindsMark(size: 30)
                Text("Mynah Finds").font(.headline)
                Spacer(minLength: 8)
                Button(page == .saved ? "Done" : "Skip", action: onComplete)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("onboardingSkip")
            }.padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch page {
                    case .welcome: welcome
                    case .sharing: sharing
                    case .example: example
                    case .saved: savedResult
                    }
                    if let saveError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(saveError).font(.subheadline).foregroundStyle(.secondary)
                            Button("Try again") { Task { await findSavedItem(resume: true) } }
                                .frame(minHeight: 44)
                        }.accessibilityIdentifier("onboardingSaveError")
                    }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)

            VStack(spacing: 6) {
                NativePrimaryButton(title: primaryTitle) {
                    switch page {
                    case .welcome, .example: move(to: .sharing)
                    case .sharing: showingCapture = true
                    case .saved: onComplete()
                    }
                }.accessibilityIdentifier("onboardingContinue")
                if page == .welcome || page == .sharing {
                    Button("Try an example") { move(to: .example) }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier("onboardingExample")
                } else if page == .example {
                    Button("Open my library", action: onComplete).frame(minHeight: 44)
                }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(NativeTheme.bg)
        .sheet(isPresented: $showingCapture, onDismiss: {
            if savedID != nil { Task { await findSavedItem() } }
        }) {
            CaptureForm(connection: nil, onLocalSave: { savedID = $0 }) { showingCapture = false }
        }
        .task { if !isReplay { await findSavedItem(resume: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !isReplay { Task { await findSavedItem() } }
        }
        .onOpenURL { url in
            guard case .library(let id) = MynahDeepLink.destination(for: url) else { return }
            savedID = id?.uuidString
            Task { await findSavedItem(resume: true) }
        }
    }

    private var primaryTitle: String {
        switch page {
        case .welcome: "Save my first find"
        case .sharing: "Save a link or photo"
        case .example: "Save my own find"
        case .saved: "Open my library"
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            ZStack(alignment: .bottomTrailing) {
                productImage(height: typeSize.isAccessibilitySize ? 170 : 220)
                    .overlay(alignment: .topLeading) {
                        Label("A little shopping inspiration", systemImage: "bag")
                            .font(.caption.weight(.semibold)).padding(10)
                            .background(.regularMaterial, in: Capsule()).padding(14)
                    }
                FindsMark(size: 104).padding(12).background(NativeTheme.bg, in: Circle())
                    .offset(x: 6, y: 16)
            }.padding(.bottom, 8)
            heading("Keep what you love.\nChoose what to buy.",
                    detail: "Save products that catch your eye. Keep the details you care about to guide your shopping recommendations.")
            Label("Start with a product link or screenshot.", systemImage: "photo.on.rectangle")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("A good find starts\nwith Share.", detail: "Save from the apps you already shop and browse in.")
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Button { changeShareStep(index) } label: {
                        VStack(spacing: 6) {
                            Text("\(index + 1)").font(.headline)
                            Text(["Share", "Mynah", "Note"][index]).font(.caption.weight(.semibold))
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(shareStep == index ? NativeTheme.accent.opacity(0.12) : NativeTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Step \(index + 1): \(shareTitles[index])")
                        .accessibilityAddTraits(shareStep == index ? .isSelected : [])
                        .accessibilityIdentifier("onboardingShareStep\(index)")
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Label("Practice preview", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                sharePreview
                Text(shareTitles[shareStep]).font(.title3.bold())
                Text(shareDetails[shareStep]).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 26))
            if shareStep == 1 {
                Text("Some apps share only a link. You can save a screenshot from Photos when you want to keep the image too.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Ready to try? Switch to a shop or social app, or save a link or photo below.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sharePreview: some View {
        switch shareStep {
        case 0:
            HStack(spacing: 16) {
                Image("sculptural-lamp").resizable().scaledToFill().frame(width: 84, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("A lamp for your reading corner").font(.headline)
                    Text("Something worth a closer look.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { changeShareStep(1) } label: {
                    Image(systemName: "square.and.arrow.up").font(.title2)
                        .frame(width: 48, height: 48).background(.blue.opacity(0.12), in: Circle())
                }.accessibilityLabel("Practice tapping Share").accessibilityIdentifier("onboardingPracticeShare")
            }
        case 1:
            HStack(spacing: 18) {
                Button { changeShareStep(2) } label: {
                    VStack(spacing: 8) {
                        FindsMark(size: 58).padding(8).background(NativeTheme.bg, in: RoundedRectangle(cornerRadius: 18))
                        Text("Mynah Finds").font(.caption.weight(.semibold))
                    }
                }.buttonStyle(.plain).accessibilityLabel("Practice choosing Mynah Finds")
                    .accessibilityIdentifier("onboardingPracticeMynah")
                Image(systemName: "arrow.left").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Look for the bird in the share sheet.").font(.subheadline)
            }
        default:
            VStack(alignment: .leading, spacing: 12) {
                Text("What caught your eye?").font(.headline)
                Text("“Warm light for my reading corner. I’d like something under $100.”")
                    .font(.body).foregroundStyle(.secondary)
                Text("Example note · Adding your own is optional.").font(.caption).foregroundStyle(.secondary)
                Button("Preview saved find") { move(to: .example) }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .accessibilityIdentifier("onboardingPreviewResult")
            }
        }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("A find with your\nshopping wish list.", detail: "Keep the product and what matters to you together.")
            VStack(alignment: .leading, spacing: 16) {
                productImage(height: 190)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Example · Not saved to your library", systemImage: "eye")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Sculptural table lamp").font(.title3.bold())
                    noteCard("Warm light for my reading corner. I’d like something under $100.")
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }.background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            Label("Your style, space and budget give shopping suggestions useful context.", systemImage: "sparkles")
                .font(.subheadline).foregroundStyle(.secondary)
        }.accessibilityIdentifier("onboardingExampleResult")
    }

    @ViewBuilder private var savedResult: some View {
        if let savedFind {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    FindsMark(size: 72)
                    Label("Saved on this iPhone", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                }
                heading("Your find is here.", detail: "Come back to it when you’re ready to decide.")
                SavedContentCard(item: savedFind, compact: true)
                if !savedFind.note.isEmpty { noteCard(savedFind.note) }
                Text("Open your library to revisit this product. Explore helps you discover shopping recommendations from your finds.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.accessibilityIdentifier("onboardingSavedResult")
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.largeTitle.bold()).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func productImage(height: CGFloat) -> some View {
        Image("sculptural-lamp").resizable().scaledToFill().frame(height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 24)).accessibilityLabel("A warm, dome-shaped table lamp")
    }
    private func noteCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What matters to you", systemImage: "text.bubble").font(.subheadline.weight(.semibold))
            Text(note).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
    private func move(to value: Page) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = value }
    }
    private func changeShareStep(_ value: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { shareStep = value }
    }
    @MainActor private func findSavedItem(resume: Bool = false) async {
        guard !loadingSave else { return }
        loadingSave = true
        defer { loadingSave = false }
        do {
            var imported = 0
            var importFailed = false
            do { imported = try await LocalLibrary.shared.importPendingShares() }
            catch { importFailed = true }
            // An unavailable share inbox must never hide an already saved local find.
            let item: SavedItem?
            if let savedID {
                item = try await LocalLibrary.shared.item(savedID)
            } else if imported > 0 || resume {
                item = try await LocalLibrary.shared.collection().first
            } else { item = nil }
            if let item {
                savedFind = item; saveError = nil; move(to: .saved)
            } else if savedID != nil || (importFailed && page == .sharing) {
                saveError = "Your find couldn’t be opened yet. Try again, or skip to your library."
            }
        } catch {
            saveError = "Your find couldn’t be opened yet. Try again, or skip to your library."
        }
    }
}

#Preview("Welcome") { FindsOnboardingView {} }
