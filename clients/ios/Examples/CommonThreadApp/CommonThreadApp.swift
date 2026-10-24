import SwiftUI
import CommonThreadKit

private enum LibraryInteractionError: LocalizedError {
    case updating
    var errorDescription: String? { "Your library is updating. Try removing this find again in a moment." }
}

@main
struct CommonThreadApp: App {
    @AppStorage("finds.appearance") private var appearance = AppAppearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            FindsAppRoot()
                .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        }
    }
}

@MainActor
struct MymahFindsView: View {
    private enum Tab: Hashable { case library, explore, profile }
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
    @State private var searchText = ""
    @AppStorage("finds.library.source") private var selectedSourceValue = ""
    @AppStorage("finds.library.grid") private var showsGrid = true
    @AppStorage("finds.library.sort") private var sortValue = LibrarySort.newest.rawValue
    @AppStorage("finds.library.scope") private var scopeValue = LibraryScope.library.rawValue
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
    private var visibleItems: [SavedItem] {
        let base = connection != nil && !query.isEmpty ? remoteSearchItems : items
        let filtered = base.filter { item in
            let flags = metadata[item.id] ?? LocalFindMetadata()
            let scopeMatches = connection != nil || (scope == .archived ? flags.isArchived : !flags.isArchived && (scope != .favorites || flags.isFavorite))
            let textMatches = connection != nil || query.isEmpty || [item.title, item.note, item.selectedText, item.originalUrl, item.source, flags.intent ?? ""]
                .contains { $0.localizedStandardContains(query) }
            return scopeMatches && textMatches && (selectedSource == nil || item.source == selectedSource)
        }
        switch LibrarySort(rawValue: sortValue) ?? .newest {
        case .newest: return filtered.sorted { $0.capturedAt > $1.capturedAt }
        case .oldest: return filtered.sorted { $0.capturedAt < $1.capturedAt }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
    private var searchIdentity: String { accountGeneration.uuidString + "|" + query }
    private var exploreRevision: String {
        items.map { item in
            let flags = connection == nil ? metadata[item.id] : nil
            return "\(item.id):\(item.revision):\(flags?.isArchived ?? false):\(flags?.isFavorite ?? false):\(flags?.intent ?? "")"
        }.joined(separator: "|")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            library.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(Tab.library)
            ExploreScreen(connection: connection, libraryRevision: exploreRevision, onLocalChange: { Task { await refresh() } }).id(accountGeneration).tabItem { Label("Explore", systemImage: "sparkles") }.tag(Tab.explore)
            profile.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(Tab.profile)
        }
        .tint(NativeTheme.accent)
        .sheet(isPresented: $showingCapture, onDismiss: { Task { await refresh() } }) {
            CaptureForm(connection: connection) {
                selectedSource = nil; scopeValue = LibraryScope.library.rawValue; searchText = ""; selectedTab = .library
                Task { await refresh() }
            }
        }
        .confirmationDialog("Discard this pending save?", isPresented: Binding(
            get: { discardingDraft != nil }, set: { if !$0 { discardingDraft = nil } }
        ), titleVisibility: .visible, presenting: discardingDraft) { draft in
            Button("Discard pending save", role: .destructive) { Task { await discard(draft) } }
            Button("Cancel", role: .cancel) { discardingDraft = nil }
        } message: { _ in Text("This removes the request from this device. It does not remove a link that has already reached your library.") }
        .task {
            if let saved = try? SharedEnvironment.read() {
                connection = saved; apiURL = saved.baseURL.absoluteString
            }
            await refresh()
            #if DEBUG
            // Deterministic visual acceptance on a connected physical iPhone.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-showExplore") { selectedTab = .explore }
            if arguments.contains("-showProfile") { selectedTab = .profile }
            if arguments.contains("-showCapture") { showingCapture = true }
            #endif
        }
        .task(id: searchIdentity) { await searchLibrary() }
        .onChange(of: selectedTab) { _, _ in FindsHaptics.selection() }
        .onChange(of: scenePhase) { _, phase in
            // Foreground reads never silently replay a permanently rejected capture.
            if phase == .active && !busy { Task { await refresh() } }
        }
    }

    private var library: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(items.isEmpty ? "Keep what catches your eye." : "Your little collection of good finds.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Label(connection == nil ? "On this iPhone" : "Shared library", systemImage: connection == nil ? "iphone" : "cloud")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { showsGrid.toggle(); FindsHaptics.selection() } label: {
                            Image(systemName: showsGrid ? "list.bullet" : "square.grid.2x2")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(showsGrid ? "Show as list" : "Show as grid")
                    }
                    feedback
                    if items.isEmpty && query.isEmpty && !busy {
                        LibraryEmptyState(symbol: "bookmark.fill", title: "A home for\nyour finds.", detail: "A photo. A lovely object. Something for later. Add your first find and make it yours.")
                        NativePrimaryButton(title: "Save your first find") { showingCapture = true }
                        Label("You can also share from Safari, Instagram or Photos.", systemImage: "square.and.arrow.up")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else {
                        libraryControls
                        sourceFilters
                        libraryResults
                    }
                    if busy { ProgressView("Updating your library").frame(maxWidth: .infinity).padding() }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(NativeTheme.bg)
            .navigationTitle("Library")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search finds, notes, categories")
            .toolbar {
                if let connection {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink { PriceWatchesView(connection: connection, trackingMode: "unknown") } label: { Image(systemName: "tag") }
                            .accessibilityLabel("Tracked prices")
                    }
                }
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

    private var libraryControls: some View {
        HStack(spacing: 12) {
            if connection == nil {
                Menu {
                    Picker("Collection", selection: $scopeValue) {
                        ForEach(LibraryScope.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                    }
                } label: {
                    Label(scope.title, systemImage: scope.symbol).font(.headline)
                        .frame(minHeight: 44)
                }.accessibilityLabel("Collection: \(scope.title)")
            } else {
                Text(query.isEmpty ? "Your finds" : "\(searchTotal) results").font(.headline)
            }
            Spacer()
            Menu {
                Picker("Sort finds", selection: $sortValue) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Sort: \((LibrarySort(rawValue: sortValue) ?? .newest).title)")
        }
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
            if !query.isEmpty || selectedSource != nil {
                Button("Clear search and filters") { searchText = ""; selectedSource = nil; FindsHaptics.selection() }
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

    private var sourceFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceButton(nil, label: "All sources")
                ForEach(sources, id: \.self) { source in sourceButton(source, label: source.capitalized) }
            }
        }
    }
    private func sourceButton(_ source: String?, label: String) -> some View {
        Button { selectedSource = source; FindsHaptics.selection() } label: {
            Text(label).font(.subheadline.weight(.semibold)).padding(.horizontal, 17).padding(.vertical, 11)
                .foregroundStyle(selectedSource == source ? NativeTheme.bg : Color.primary)
                .background(selectedSource == source ? Color.primary : NativeTheme.surface, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selectedSource == source ? .isSelected : [])
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
        } label: { SavedContentCard(item: item, compact: !grid, connection: connection) }
        .buttonStyle(.plain).accessibilityIdentifier("savedItem-\(item.id)")
        .contextMenu {
            if connection == nil {
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
                            Text("All the things you come back to.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                if let connection {
                    Section("Your library") {
                        LabeledContent("Account", value: connection.accountId)
                        LabeledContent("Connection", value: connection.baseURL.host ?? connection.baseURL.absoluteString)
                    }
                } else {
                    Section("On this iPhone") {
                        Label("Local library", systemImage: "iphone")
                        Text("Save, browse and search right here. Your finds stay on this device. Connecting a shared library keeps these local finds separate.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
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
                    } header: { Text("Optional connection") } footer: {
                        Text("A shared library uses a server address and access key. Connecting switches libraries; your local finds stay on this iPhone.")
                    }
                }
                Section(connection == nil ? "Storage" : "Sync") {
                    Text(status).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("connectionStatus")
                    if connection == nil {
                        LabeledContent("App library storage", value: ByteCountFormatter.string(fromByteCount: Int64(localStorageBytes), countStyle: .file))
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
                                        favoriteCount: metadata.values.filter { $0.isFavorite }.count,
                                        archivedCount: metadata.values.filter { $0.isArchived }.count)
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
