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
        Section("Make it yours") {
            Picker(selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            .accessibilityIdentifier("appearancePicker")
            Toggle(isOn: $haptics) { Label("Haptic feedback", systemImage: "hand.tap") }
                .accessibilityIdentifier("hapticsToggle")
            Picker(selection: $showsGrid) {
                Text("Grid").tag(true)
                Text("List").tag(false)
            } label: { Label("Library layout", systemImage: "square.grid.2x2") }
            Picker(selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
            } label: { Label("Sort finds", systemImage: "arrow.up.arrow.down") }
        }
        Section(localOnly ? "Your collection" : "Loaded collection") {
            LabeledContent("Finds", value: String(items.count))
            LabeledContent("With images", value: String(items.filter(\.hasImage).count))
            if localOnly {
                LabeledContent("Favorites", value: String(favoriteCount))
                LabeledContent("Archived", value: String(archivedCount))
            }
        }
        Section("A little help") {
            NavigationLink { ShareGuideView() } label: {
                Label("Save from other apps", systemImage: "square.and.arrow.up")
            }
            NavigationLink { FindsPrivacyView() } label: {
                Label("Your data & permissions", systemImage: "hand.raised")
            }
            Button { showingIntro = true; FindsHaptics.selection() } label: {
                Label("See the introduction again", systemImage: "play.rectangle")
            }
            .sheet(isPresented: $showingIntro) {
                FindsOnboardingView { showingIntro = false }
                    .presentationDragIndicator(.visible)
            }
        }
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        } footer: {
            Text("Mynah Finds · Keep what catches your eye.")
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
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
                guideRow(4, "Choose Mynah Finds & keep the why", "Tap Mynah Finds in the share sheet. Type a note or use the microphone on your iPhone keyboard to dictate it in the share sheet. You can edit it and use the app’s voice-note button after saving.", symbol: "text.bubble")
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
                Text("Local finds, photos, files and notes are stored by the app on this device. They are not automatically uploaded when you connect a separate shared library.")
            }
            Section("Photos & voice") {
                Text("Choose individual photos or files to share with the app. The app’s voice-note button requests microphone and speech recognition permission when you use it. In a share sheet, use the iPhone keyboard’s dictation button. Review and edit the transcript before saving.")
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
