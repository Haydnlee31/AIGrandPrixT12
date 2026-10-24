import SwiftUI
import UIKit
import CommonThreadKit

/// Settings live in Profile. These controls operate on persistent app preferences.
struct ProfileSettingsSections: View {
    let items: [SavedItem]
    let localOnly: Bool
    let favoriteCount: Int
    let archivedCount: Int
    @AppStorage("finds.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("finds.haptics") private var haptics = true
    @AppStorage("finds.library.grid") private var showsGrid = true
    @AppStorage("finds.library.sort") private var sort = LibrarySort.newest.rawValue
    @State private var showingIntro = false

    var body: some View {
        Section("Shopping intelligence") {
            NavigationLink { IntelligenceSettingsView() } label: {
                Label { Text("AI & privacy") } icon: { Image(systemName: "sparkles").foregroundStyle(.purple) }
            }
        }
        Section("Preferences") {
            Picker(selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            } label: { Label { Text("Appearance") } icon: { Image(systemName: "circle.lefthalf.filled").foregroundStyle(.indigo) } }
            .accessibilityIdentifier("appearancePicker")
            Toggle(isOn: $haptics) { Label { Text("Haptics") } icon: { Image(systemName: "hand.tap.fill").foregroundStyle(.orange) } }
                .accessibilityIdentifier("hapticsToggle")
            Picker(selection: $showsGrid) {
                Text("Grid").tag(true)
                Text("List").tag(false)
            } label: { Label("Library layout", systemImage: "square.grid.2x2") }
            Picker(selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
            } label: { Label("Sort finds", systemImage: "arrow.up.arrow.down") }
        }
        Section("Help") {
            NavigationLink { ShareGuideView() } label: {
                Label("Save from other apps", systemImage: "square.and.arrow.up")
            }
            NavigationLink { FindsPrivacyView() } label: {
                Label("Your data & permissions", systemImage: "hand.raised")
            }
            Button { showingIntro = true; FindsHaptics.selection() } label: {
                Label("Introduction", systemImage: "play.rectangle")
            }
            .sheet(isPresented: $showingIntro) {
                FindsOnboardingView { showingIntro = false }
                    .presentationDragIndicator(.visible)
            }
        }
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        }
        .onChange(of: appearance) { _, _ in FindsHaptics.selection() }
        .onChange(of: haptics) { _, enabled in if enabled { FindsHaptics.selection() } }
    }
}

private struct ShareGuideView: View {
    var body: some View {
        List {
            Section {
                Text("A find can start anywhere.").font(.title2.bold()).padding(.vertical, 8)
                guideRow(1, "Open something you love", "A page in Safari, an Instagram post, or a photo in your library.", symbol: "safari")
                guideRow(2, "Open the share sheet", "In Safari or Photos, tap Share. In Instagram, tap the paper plane and then Share to…", symbol: "square.and.arrow.up")
                guideRow(3, "Put Mynah Finds first", "Swipe to the end of the app row and tap More, then Edit. Tap the plus beside Mynah Finds to add it to Favorites. Drag its reorder handle to the top, then tap Done.", symbol: "bookmark")
                guideRow(4, "Keep the why, then carry on", "Add a note or use your iPhone keyboard’s dictation button. Save returns you to the app you were using. In Mynah, the voice-note button transcribes with OpenAI.", symbol: "text.bubble")
            }
            Section {
                Text("Apps choose what they share. An Instagram post may share a link rather than its photo. You can also add a screenshot from Photos inside Mynah Finds.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Save from anywhere").navigationBarTitleDisplayMode(.inline)
    }
    private func guideRow(_ number: Int, _ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title3).foregroundStyle(NativeTheme.accent)
                .frame(width: 36, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(number). \(title)").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10)
    }
}

private struct FindsPrivacyView: View {
    var body: some View {
        List {
            Section("Local library") {
                Label("Your saves stay on this iPhone", systemImage: "iphone")
                Text("Local finds, photos, files and notes are stored by the app on this device. A separate shared library does not automatically import them. When shopping intelligence is connected, the selected photo and product context are sent to OpenAI to create suggestions and analysis. Disconnect intelligence in Profile to stop this processing.")
            }
            Section("Photos & voice") {
                Text("Choose individual photos or files to share with the app. Voice notes in Mynah use the microphone and send up to one minute of audio to OpenAI through your configured AI connection. The relay doesn’t save audio or transcripts. Temporary recordings are removed after capture; retry audio stays in memory until success or dismissal. Review the editable text before saving. Share sheets use the iPhone keyboard’s own dictation.")
                Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                    Label("Open iPhone permissions", systemImage: "gearshape")
                }
            }
            Section("Shared library") {
                Text("When connected, saves made in your shared library go to the server you chose. AI features may send shared content to the providers configured by that server. Your access key is kept in the iPhone Keychain.")
            }
            Section("You are in control") {
                Text("Remove a find from its options menu. Removing a local find removes its saved content on this iPhone. Removing a shared find affects that account’s library on connected devices.")
                Text("Opening an original link takes you to that website, where its own privacy practices apply.")
            }
        }
        .font(.body)
        .navigationTitle("Your data").navigationBarTitleDisplayMode(.inline)
    }
}
