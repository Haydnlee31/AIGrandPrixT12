import SwiftUI
import UIKit
import CommonThreadKit

private enum LibraryInteractionError: LocalizedError {
    case updating
    var errorDescription: String? { "Your library is updating. Try removing this find again in a moment." }
}

@main @MainActor
struct CommonThreadApp: App {
    @State private var appearance: AppAppearanceState
    init() {
        var initial: AppAppearance?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-finds.appearance"), arguments.indices.contains(index + 1) {
            initial = AppAppearance(rawValue: arguments[index + 1])
        }
        #endif
        _appearance = State(initialValue: AppAppearanceState(initial: initial) { value in
            SharedAppearance.set(value.rawValue)
            AppearanceWindows.apply(value.interfaceStyle)
        })
    }
    var body: some Scene {
        WindowGroup {
            FindsAppearanceRoot().environment(appearance)
        }
    }
}

private struct FindsAppearanceRoot: View {
    @Environment(AppAppearanceState.self) private var appearance
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        FindsAppRoot()
            .preferredColorScheme(appearance.selection.colorScheme)
            .background(WindowAppearance(appearance: appearance.selection))
            .onAppear { appearance.applyToCurrentPresentation() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { appearance.applyToCurrentPresentation() }
            }
    }
}

@MainActor private enum AppearanceWindows {
    static func apply(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { apply(style, to: window) }
        }
    }
    static func apply(_ style: UIUserInterfaceStyle, to window: UIWindow) {
        if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
        if let root = window.rootViewController { apply(style, to: root) }
    }
    private static func apply(_ style: UIUserInterfaceStyle, to controller: UIViewController) {
        if controller.overrideUserInterfaceStyle != style {
            controller.overrideUserInterfaceStyle = style
            controller.setNeedsStatusBarAppearanceUpdate()
        }
        for child in controller.children { apply(style, to: child) }
        if let presented = controller.presentedViewController { apply(style, to: presented) }
    }
}

/// Reapplies the single selected mode when SwiftUI attaches a new host window.
private struct WindowAppearance: UIViewRepresentable {
    let appearance: AppAppearance
    func makeUIView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.isUserInteractionEnabled = false
        view.apply(appearance)
        return view
    }
    func updateUIView(_ uiView: AppearanceView, context: Context) { uiView.apply(appearance) }
    final class AppearanceView: UIView {
        private var style: UIUserInterfaceStyle = .unspecified
        func apply(_ appearance: AppAppearance) {
            style = appearance.interfaceStyle
            if let window { AppearanceWindows.apply(style, to: window) }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { AppearanceWindows.apply(style, to: window) }
        }
    }
}

@MainActor
struct MymahFindsView: View {
    private enum Tab: Hashable { case library, explore, radar, profile }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedTab: Tab = .library
    @State private var apiURL = ""
    @State private var token = ""
    @State private var items: [SavedItem] = []
    @State private var pendingSaves: [PendingCapture] = []
    @State private var pendingErrors: [String: String] = [:]
    @State private var nextOffset: Int?
    @State private var connection: SharedEnvironment?
    @State private var accountGeneration = UUID()
    @State private var status = "Your finds stay on this iPhone."
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var showingCapture = false
    @State private var linkedFind: SavedItem?
    @State private var searchText = ""
    @AppStorage("finds.library.source") private var selectedSourceValue = ""
    @AppStorage("finds.library.grid") private var showsGrid = true
    @AppStorage("finds.library.sort") private var sortValue = LibrarySort.newest.rawValue
    @AppStorage("finds.library.scope") private var scopeValue = LibraryScope.library.rawValue
    @AppStorage("finds.library.format") private var formatValue = LibraryFormat.all.rawValue
    @State private var metadata: [String: LocalFindMetadata] = [:]
    @State private var localStorageBytes = 0
    @State private var remoteSearchItems: [SavedItem] = []
    @State private var searchNextOffset: Int?
    @State private var searchTotal = 0
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchRequestID = UUID()
    @State private var discardingDraft: PendingCapture?

    private var selectedSource: String? {
        get { selectedSourceValue.isEmpty ? nil : selectedSourceValue }
        nonmutating set { selectedSourceValue = newValue ?? "" }
    }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sources: [String] { Array(Set((items + remoteSearchItems).map(\.source))).sorted() }
    private var scope: LibraryScope { connection == nil ? LibraryScope(rawValue: scopeValue) ?? .library : .library }
    private var format: LibraryFormat { LibraryFormat(rawValue: formatValue) ?? .all }
    private var visibleItems: [SavedItem] {
        let base = connection != nil && !query.isEmpty ? remoteSearchItems : items
        let filtered = base.filter { item in
            let flags = metadata[item.id] ?? LocalFindMetadata()
            let scopeMatches = connection != nil || (scope == .archived ? flags.isArchived : !flags.isArchived && (scope != .favorites || flags.isFavorite))
            let textMatches = connection != nil || query.isEmpty || [item.title, item.note, item.selectedText, item.originalUrl, item.source, flags.selectedIntents.joined(separator: " "), flags.analysis?.searchableText ?? ""]
                .contains { $0.localizedStandardContains(query) }
            let formatMatches: Bool
            switch format {
            case .all: formatMatches = true
            case .images: formatMatches = item.hasImage || flags.attachments.contains(where: \.isImage)
            case .links: formatMatches = !item.originalUrl.isEmpty
            case .voice: formatMatches = flags.hasVoiceNote == true || flags.attachments.contains(where: \.isAudio)
            case .files: formatMatches = flags.attachments.contains { !$0.isImage && !$0.isAudio }
            case .text: formatMatches = !item.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return scopeMatches && textMatches && formatMatches && (selectedSource == nil || item.source == selectedSource)
        }
        return filtered.sorted { first, second in
            let firstPinned = metadata[first.id]?.pinned ?? false
            let secondPinned = metadata[second.id]?.pinned ?? false
            if connection == nil, firstPinned != secondPinned { return firstPinned }
            switch LibrarySort(rawValue: sortValue) ?? .newest {
            case .newest: return first.capturedAt > second.capturedAt
            case .oldest: return first.capturedAt < second.capturedAt
            case .title: return first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
        }
    }

    private var searchIdentity: String { accountGeneration.uuidString + "|" + query }
    private var exploreRevision: String {
        items.map { item in
            let flags = connection == nil ? metadata[item.id] : nil
            return "\(item.id):\(item.revision):\(flags?.isArchived ?? false):\(flags?.isFavorite ?? false):\(flags?.pinned ?? false):\(flags?.selectedIntents.joined(separator: " · ") ?? ""):\(flags?.analysis?.analyzedAt ?? 0)"
        }.joined(separator: "|")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            library.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(Tab.library)
            ExploreScreen(connection: connection, libraryRevision: exploreRevision, onLocalChange: { Task { await refresh() } }).id(accountGeneration).tabItem { Label("Explore", systemImage: "sparkles") }.tag(Tab.explore)
            RadarScreen(libraryRevision: exploreRevision, onChanged: { Task { await refresh() } }).id(accountGeneration)
                .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }.tag(Tab.radar)
            profile.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(Tab.profile)
        }
        .tint(NativeTheme.accent)
        .sheet(isPresented: $showingCapture, onDismiss: { Task { await refresh() } }) {
            CaptureForm(connection: connection) {
                selectedSource = nil; scopeValue = LibraryScope.library.rawValue; formatValue = LibraryFormat.all.rawValue; searchText = ""; selectedTab = .library
                Task { await refresh() }
            }
        }
        .sheet(item: $linkedFind) { find in
            NavigationStack {
                SavedContentView(item: find, stillSaved: items.contains { $0.id == find.id }, localOnly: connection == nil,
                    connection: connection, onChanged: { Task { await refresh() } },
                    onDelete: { id, key in try await removeSave(id, key: key) })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { linkedFind = nil } } }
            }
        }
        .confirmationDialog("Discard this pending save?", isPresented: Binding(
            get: { discardingDraft != nil }, set: { if !$0 { discardingDraft = nil } }
        ), titleVisibility: .visible, presenting: discardingDraft) { draft in
            Button("Discard pending save", role: .destructive) { Task { await discard(draft) } }
            Button("Cancel", role: .cancel) { discardingDraft = nil }
        } message: { _ in Text("This removes the request from this device. It does not remove a link that has already reached your library.") }
        .task {
            #if DEBUG
            do { try CaptureIntelligence.importDevelopmentConfiguration() }
            catch { errorMessage = "Shopping intelligence setup needs attention. Your local library is still available." }
            #endif
            #if DEBUG
            // Explicit device recovery: disconnect without touching local finds or photos.
            if ProcessInfo.processInfo.arguments.contains("-restoreLocalLibrary"),
               let saved = try? SharedEnvironment.read() {
                try? saved.signOut()
            }
            #endif
            if let saved = try? SharedEnvironment.read() {
                connection = saved; apiURL = saved.baseURL.absoluteString
            }
            await refresh()
            #if DEBUG
            // Deterministic visual acceptance on a connected physical iPhone.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-showExplore") || arguments.contains("-showYourFinds") || arguments.contains("-showTasteLab") { selectedTab = .explore }
            if arguments.contains("-showSavedPhoto") || arguments.contains("-showRefinement") { linkedFind = items.first { $0.hasImage && $0.client != "sample" } }
            if arguments.contains("-showSavedLink") { linkedFind = items.first { !$0.originalUrl.isEmpty && $0.client != "sample" } }
            if arguments.contains("-showProfile") { selectedTab = .profile }
            if arguments.contains("-showRadar") { selectedTab = .radar }
            if arguments.contains("-showCapture") || arguments.contains("-demoWatchDraft") { showingCapture = true }
            #endif
        }
        .onOpenURL { url in
            guard case .library(let savedFindID) = MynahDeepLink.destination(for: url) else { return }
            selectedTab = .library; showingCapture = false
            Task {
                await refresh()
                if let savedFindID {
                    if connection == nil { linkedFind = try? await LocalLibrary.shared.item(savedFindID.uuidString) }
                    else { linkedFind = items.first { $0.id.caseInsensitiveCompare(savedFindID.uuidString) == .orderedSame } }
                }
            }
        }
        .task(id: searchIdentity) { await searchLibrary() }
        .onChange(of: selectedTab) { _, _ in FindsHaptics.selection(); Task { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            // Foreground reads never silently replay a permanently rejected capture.
            if phase == .active && !busy { Task { await refresh() } }
        }
    }

    private var library: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    feedback
                    if items.isEmpty && query.isEmpty && !busy {
                        LibraryEmptyState(symbol: "bookmark.fill", title: "Your first find.", detail: "Add a photo, link or note.")
                        NativePrimaryButton(title: "Save your first find") { showingCapture = true }
                    } else {
                        formatFilters
                        if scope != .library || selectedSource != nil {
                            HStack {
                                Label(selectedSource?.capitalized ?? scope.title, systemImage: scope.symbol)
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                                Spacer()
                                Button("Clear") { scopeValue = LibraryScope.library.rawValue; selectedSource = nil; formatValue = LibraryFormat.all.rawValue }
                                    .font(.subheadline)
                            }
                        }
                        libraryResults
                    }
                    if busy { ProgressView("Updating your library").frame(maxWidth: .infinity).padding() }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(NativeTheme.bg)
            .navigationTitle("Library")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search your finds")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { libraryOptions }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCapture = true; FindsHaptics.selection() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Save a find").accessibilityIdentifier("addSave")
                        .disabled(busy)
                }
            }
            .refreshable {
                await refresh()
                if !query.isEmpty { await searchLibrary(debounce: false) }
            }
        }.id(accountGeneration)
    }

    private var formatFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(LibraryFormat.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { formatValue = option.rawValue }
                        FindsHaptics.selection()
                    } label: {
                        Label(option.title, systemImage: option.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(format == option ? option.color : Color.secondary)
                            .padding(.horizontal, 14).frame(minHeight: 42)
                            .background(format == option ? option.color.opacity(0.12) : NativeTheme.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(format == option ? option.color.opacity(0.25) : .clear, lineWidth: 1) }
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(format == option ? .isSelected : [])
                        .accessibilityIdentifier("libraryFormat_\(option.rawValue)")
                }
            }
        }.scrollIndicators(.hidden)
    }

    private var libraryOptions: some View {
        Menu {
            if connection == nil {
                Picker("Collection", selection: $scopeValue) {
                    ForEach(LibraryScope.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
            }
            Picker("Layout", selection: $showsGrid) {
                Label("Grid", systemImage: "square.grid.2x2").tag(true)
                Label("List", systemImage: "list.bullet").tag(false)
            }
            Picker("Sort", selection: $sortValue) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if sources.count > 1 {
                Picker("Source", selection: $selectedSourceValue) {
                    Text("All sources").tag("")
                    ForEach(sources, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        } label: { Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.blue) }
        .accessibilityLabel("Library options")
    }

    @ViewBuilder private var libraryResults: some View {
        if let searchError, !query.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(searchError, systemImage: "exclamationmark.circle").font(.subheadline)
                Button("Retry search") { Task { await searchLibrary(debounce: false) } }.disabled(searching)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
        }
        if searching && remoteSearchItems.isEmpty {
            ProgressView("Searching your shared library").frame(maxWidth: .infinity).padding(30)
        } else if visibleItems.isEmpty && !busy {
            LibraryEmptyState(symbol: scope == .favorites ? "heart" : scope == .archived ? "archivebox" : "text.magnifyingglass",
                              title: scope == .favorites && query.isEmpty ? "Your favorites,\nall together." : scope == .archived && query.isEmpty ? "A little room\nfor later." : "No matches yet.",
                              detail: scope == .favorites && query.isEmpty ? "Open a find or touch and hold a card to add it to Favorites." : scope == .archived && query.isEmpty ? "Archive a find to keep it without showing it in your main library." : "Try another word, or clear your filters to see more finds.")
            if !query.isEmpty || selectedSource != nil || format != .all || scope != .library {
                Button("Clear search and filters") {
                    searchText = ""; selectedSource = nil; formatValue = LibraryFormat.all.rawValue
                    scopeValue = LibraryScope.library.rawValue; FindsHaptics.selection()
                }
            }
        } else {
            savedItems(visibleItems, grid: showsGrid && !typeSize.isAccessibilitySize)
        }
        if connection != nil && !query.isEmpty {
            if let offset = searchNextOffset {
                Button("Load more search results") { Task { await searchLibrary(offset: offset, debounce: false) } }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 48).disabled(searching)
            }
        } else { moreItemsButton }
    }

    @ViewBuilder private func savedItems(_ saved: [SavedItem], grid: Bool) -> some View {
        if grid {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(saved) { item in itemLink(item, grid: true) }
            }
        } else {
            LazyVStack(spacing: 12) { ForEach(saved) { item in itemLink(item, grid: false) } }
        }
    }
    private func itemLink(_ item: SavedItem, grid: Bool) -> some View {
        NavigationLink {
            SavedContentView(item: item, stillSaved: (items + remoteSearchItems).contains { $0.id == item.id }, localOnly: connection == nil,
                             connection: connection, onChanged: { Task { await refresh(); if !query.isEmpty { await searchLibrary(debounce: false) } } }) { id, key in
                try await removeSave(id, key: key)
            }
        } label: {
            SavedContentCard(item: item, compact: !grid, connection: connection, pinned: metadata[item.id]?.pinned ?? false,
                insight: metadata[item.id]?.analysis.map { ProductInsightSummary.firstSentence($0.summary) },
                mergedSaveCount: metadata[item.id]?.sourceItems?.count ?? 1)
        }
        .buttonStyle(.plain).accessibilityIdentifier("savedItem-\(item.id)")
        .contextMenu {
            if connection == nil {
                Button { Task { await changePin(item) } } label: {
                    Label(metadata[item.id]?.pinned == true ? "Unpin" : "Pin", systemImage: metadata[item.id]?.pinned == true ? "pin.slash" : "pin.fill")
                }
                Button { Task { await changeFavorite(item) } } label: {
                    Label(metadata[item.id]?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites", systemImage: metadata[item.id]?.isFavorite == true ? "heart.slash" : "heart")
                }
                Button { Task { await changeArchive(item) } } label: {
                    Label(metadata[item.id]?.isArchived == true ? "Move to Library" : "Archive find", systemImage: metadata[item.id]?.isArchived == true ? "tray.and.arrow.up" : "archivebox")
                }
            }
        }
    }

    private var profile: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        FindsMark(size: 60)
                            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Mynah Finds").font(.title2.bold())
                        }
                    }.padding(.vertical, 8)
                }
                if let connection {
                    Section("Your library") {
                        LabeledContent("Account", value: connection.accountId)
                        LabeledContent("Connection", value: connection.baseURL.host ?? connection.baseURL.absoluteString)
                    }
                } else {
                    Section {
                        DisclosureGroup("Connect a shared library") {
                            TextField("Server address", text: $apiURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("serverURL")
                            SecureField("Access key", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("accessToken")
                            Button("Connect your library") { Task { await connect() } }
                                .font(.headline).disabled(busy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiURL.isEmpty)
                                .accessibilityIdentifier("connectLibrary")
                        }
                    } header: { Text("Sync") }
                }
                Section(connection == nil ? "Storage" : "Sync") {
                    if connection != nil { Text(status).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("connectionStatus") }
                    if connection == nil {
                        LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: Int64(localStorageBytes), countStyle: .file))
                    }
                    if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red) }
                    if busy { ProgressView() }
                    if connection != nil { Button("Sync library") { Task { await sync() } }.disabled(busy) }
                }
                if !pendingSaves.isEmpty {
                    Section {
                        ForEach(pendingSaves) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.request.title).font(.headline)
                                Text(pendingErrors[draft.id] ?? "Waiting to sync")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("Discard pending save", role: .destructive) { discardingDraft = draft }.disabled(busy)
                            }.padding(.vertical, 4)
                        }
                    } header: { Text("Pending on this device") } footer: {
                        Text("These requests have not been confirmed. Sync library retries them with their original notes. Discard a rejected request to save an edited version.")
                    }
                }
                ProfileSettingsSections(items: items, localOnly: connection == nil,
                                        favoriteCount: items.filter { metadata[$0.id]?.isFavorite == true }.count,
                                        archivedCount: items.filter { metadata[$0.id]?.isArchived == true }.count)
                if connection != nil {
                    Section {
                        Button("Sign out", role: .destructive) { signOut() }.disabled(busy)
                    } footer: { Text("Pending saves remain on this device for this account. You can discard them above before signing out.") }
                }
            }
            .scrollContentBackground(.hidden).background(NativeTheme.bg).navigationTitle("Profile")
        }.id(accountGeneration)
    }

    @ViewBuilder private var feedback: some View {
        if let errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label(errorMessage, systemImage: "exclamationmark.circle").font(.subheadline)
                Button("Try again") { Task { await refresh() } }.font(.subheadline.bold()).disabled(busy)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("libraryError")
        }
        if !pendingSaves.isEmpty {
            Button { selectedTab = .profile } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("\(pendingSaves.count) \(pendingSaves.count == 1 ? "save" : "saves") waiting to sync").font(.subheadline.weight(.semibold))
                    Spacer(); Image(systemName: "chevron.right").font(.caption.bold())
                }.padding(16).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            }.buttonStyle(.plain)
        }
    }
    @ViewBuilder private var moreItemsButton: some View {
        if let offset = nextOffset {
            Button("Load more saved items") { Task { await refresh(offset: offset) } }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 48).disabled(busy)
        }
    }

    private func changePin(_ item: SavedItem) async {
        guard connection == nil else { return }
        do {
            try await LocalLibrary.shared.setPinned(item.id, !(metadata[item.id]?.pinned ?? false))
            metadata = try await LocalLibrary.shared.metadata(); FindsHaptics.selection()
        } catch { errorMessage = error.localizedDescription }
    }
    private func changeFavorite(_ item: SavedItem) async {
        guard connection == nil, !busy else { return }
        do {
            try await LocalLibrary.shared.setFavorite(item.id, !(metadata[item.id]?.isFavorite ?? false))
            metadata = try await LocalLibrary.shared.metadata(); FindsHaptics.success()
        } catch { errorMessage = error.localizedDescription }
    }
    private func changeArchive(_ item: SavedItem) async {
        guard connection == nil, !busy else { return }
        do {
            try await LocalLibrary.shared.setArchived(item.id, !(metadata[item.id]?.isArchived ?? false))
            metadata = try await LocalLibrary.shared.metadata(); FindsHaptics.success()
        } catch { errorMessage = error.localizedDescription }
    }
    private func searchLibrary(offset: Int = 0, debounce: Bool = true) async {
        if offset > 0 && searching { return }
        let requestID = UUID(); searchRequestID = requestID
        let requestedQuery = query
        let generation = accountGeneration
        guard let environment = connection, !requestedQuery.isEmpty else {
            remoteSearchItems = []; searchError = nil; searchNextOffset = nil; searchTotal = 0; searching = false
            return
        }
        if offset == 0 { remoteSearchItems = []; searchNextOffset = nil; searchError = nil }
        searching = true
        defer { if searchRequestID == requestID { searching = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            let client = try environment.client()
            try await environment.verify(client)
            let page = try await client.searchLibrary(query: requestedQuery, offset: offset)
            try Task.checkCancellation()
            guard searchRequestID == requestID, sameAccount(environment, generation: generation), query == requestedQuery else { return }
            if offset == 0 { remoteSearchItems = page.items } else {
                var existing = Set(remoteSearchItems.map(\.id))
                remoteSearchItems += page.items.filter { existing.insert($0.id).inserted }
            }
            searchNextOffset = page.nextOffset; searchTotal = page.total; searchError = nil
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, searchRequestID == requestID, sameAccount(environment, generation: generation), query == requestedQuery else { return }
            searchError = error.localizedDescription
        }
    }

    private func sameAccount(_ environment: SharedEnvironment, generation: UUID) -> Bool {
        accountGeneration == generation && connection?.accountId == environment.accountId && connection?.baseURL == environment.baseURL
    }
    private func connect() async {
        guard !busy else { return }
        busy = true; errorMessage = nil; defer { busy = false }
        do {
            guard let input = URL(string: apiURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ClientError.invalidBaseURL }
            let suppliedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            // Validate before canonicalizing, so a URL path is never silently discarded.
            _ = try CommonThreadClient(baseURL: input) { suppliedToken }
            guard var parts = URLComponents(url: input, resolvingAgainstBaseURL: false) else { throw ClientError.invalidBaseURL }
            parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased(); parts.path = ""
            guard let url = parts.url else { throw ClientError.invalidBaseURL }
            let client = try CommonThreadClient(baseURL: url) { suppliedToken }
            let account = try await client.account()
            _ = try await client.capabilities()
            let environment = SharedEnvironment(baseURL: url, accountId: account.userId)
            try environment.store(token: suppliedToken); try environment.store()
            accountGeneration = UUID(); connection = environment; token = ""; apiURL = url.absoluteString
            items = []; pendingSaves = []; nextOffset = nil; selectedSource = nil; pendingErrors = [:]
            let generation = accountGeneration
            await loadPending(environment, generation: generation)
            let page = try await client.collection()
            guard sameAccount(environment, generation: generation) else { return }
            items = page.items; nextOffset = page.nextOffset
            status = "Your library is connected."; selectedTab = .library
        } catch { errorMessage = error.localizedDescription; status = "Connection needs attention." }
    }
    private func refresh(offset: Int = 0) async {
        guard !busy else { return }
        busy = true; errorMessage = nil; defer { busy = false }
        let generation = accountGeneration
        guard let environment = connection else {
            var importError: String?
            do { _ = try await LocalLibrary.shared.importPendingShares() }
            catch { importError = "A shared find could not be imported yet. Your existing library is still available. " + error.localizedDescription }
            do {
                let saved = try await LocalLibrary.shared.collection()
                let localMetadata = try await LocalLibrary.shared.metadata()
                let bytes = await LocalLibrary.shared.storageBytes()
                guard connection == nil, accountGeneration == generation else { return }
                items = saved; metadata = localMetadata; localStorageBytes = bytes
                nextOffset = nil; pendingSaves = []; pendingErrors = [:]
                if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
                errorMessage = importError
                status = importError == nil ? "Your finds are saved on this iPhone." : "Your library is open. A pending share needs attention."
            } catch {
                guard connection == nil, accountGeneration == generation else { return }
                errorMessage = error.localizedDescription; status = "Your local library could not be opened."
            }
            return
        }
        await loadPending(environment, generation: generation)
        do {
            let client = try environment.client(); try await environment.verify(client)
            let page = try await client.collection(offset: offset)
            guard sameAccount(environment, generation: generation) else { return }
            if offset == 0 { items = page.items } else {
                var existing = Set(items.map(\.id)); items += page.items.filter { existing.insert($0.id).inserted }
            }
            nextOffset = page.nextOffset
            if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
            status = "Your library is up to date."
        } catch {
            guard sameAccount(environment, generation: generation) else { return }
            errorMessage = error.localizedDescription; status = "Your saved content could not be refreshed."
        }
    }
    private func sync() async {
        guard let environment = connection, !busy else { return }
        busy = true; errorMessage = nil; defer { busy = false }
        let generation = accountGeneration
        var duplicates = 0
        var failures = 0
        var libraryRefreshed = false
        do {
            let client = try environment.client(); try await environment.verify(client)
            let outbox = try SharedEnvironment.outbox()
            let drafts = try await outbox.pending(accountId: environment.accountId, baseURL: environment.baseURL)
            for draft in drafts {
                guard sameAccount(environment, generation: generation) else { return }
                do {
                    let receipt = try await client.capture(draft.request, key: draft.key)
                    try await outbox.remove(draft)
                    if receipt.duplicate { duplicates += 1 }
                    pendingErrors.removeValue(forKey: draft.id)
                } catch {
                    failures += 1; pendingErrors[draft.id] = error.localizedDescription
                    if let apiError = error as? APIError, apiError.status == 401 { break }
                }
            }
        } catch { errorMessage = error.localizedDescription }
        // A rejected pending request must never prevent reading already-saved content.
        do {
            let client = try environment.client(); try await environment.verify(client)
            let page = try await client.collection()
            guard sameAccount(environment, generation: generation) else { return }
            items = page.items; nextOffset = page.nextOffset
            libraryRefreshed = true
            if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
        } catch { errorMessage = error.localizedDescription }
        guard sameAccount(environment, generation: generation) else { return }
        await loadPending(environment, generation: generation)
        if !libraryRefreshed { status = "Your library could not be refreshed. Try again when the connection is ready." }
        else if failures > 0 { status = "Library refreshed. Some pending saves need attention below." }
        else if duplicates > 0 { status = "Synced. \(duplicates) links were already saved; their original notes and text were kept." }
        else if errorMessage == nil { status = "Your library is up to date." }
    }
    private func loadPending(_ environment: SharedEnvironment, generation: UUID) async {
        do {
            let pending = try await SharedEnvironment.outbox().pending(accountId: environment.accountId, baseURL: environment.baseURL)
            guard sameAccount(environment, generation: generation) else { return }
            pendingSaves = pending
        } catch {
            guard sameAccount(environment, generation: generation) else { return }
            errorMessage = "Pending saves could not be read: \(error.localizedDescription)"
        }
    }
    private func discard(_ draft: PendingCapture) async {
        guard let environment = connection, !busy, draft.accountId == environment.accountId, draft.baseURL == environment.baseURL else { return }
        busy = true; defer { busy = false; discardingDraft = nil }
        do {
            try await SharedEnvironment.outbox().remove(draft)
            pendingErrors.removeValue(forKey: draft.id)
            await loadPending(environment, generation: accountGeneration)
        } catch { errorMessage = error.localizedDescription }
    }
    private func removeSave(_ id: String, key: MutationKey) async throws {
        guard !busy else { throw LibraryInteractionError.updating }
        busy = true; defer { busy = false }
        let generation = accountGeneration
        guard let environment = connection else {
            try await LocalLibrary.shared.delete(id)
            guard connection == nil, accountGeneration == generation else { return }
            items.removeAll { $0.id == id }; metadata.removeValue(forKey: id)
            localStorageBytes = await LocalLibrary.shared.storageBytes()
            if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
            status = "Removed from this iPhone."
            return
        }
        let client = try environment.client(); try await environment.verify(client)
        _ = try await client.deleteSavedItem(id, key: key)
        guard sameAccount(environment, generation: generation) else { throw SetupError.accountChanged }
        items.removeAll { $0.id == id }; remoteSearchItems.removeAll { $0.id == id }
        do {
            let page = try await client.collection()
            guard sameAccount(environment, generation: generation) else { return }
            items = page.items; nextOffset = page.nextOffset
            if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
            status = "Removed from your library."
        } catch {
            // Deletion was acknowledged; a subsequent read failure must not imply it failed.
            errorMessage = "This find was removed. The rest of your library could not be refreshed: \(error.localizedDescription)"
        }
    }
    private func signOut() {
        do {
            try connection?.signOut()
            accountGeneration = UUID(); connection = nil; items = []; pendingSaves = []; pendingErrors = [:]
            remoteSearchItems = []; searchNextOffset = nil; searchError = nil
            nextOffset = nil; selectedSource = nil; searchText = ""; token = ""; errorMessage = nil; status = "Opening your local library."
            Task { await refresh() }
        } catch { errorMessage = error.localizedDescription }
    }
}
