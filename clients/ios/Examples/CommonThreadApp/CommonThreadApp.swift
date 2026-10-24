import SwiftUI
import CommonThreadKit

private enum LibraryInteractionError: LocalizedError {
    case updating
    var errorDescription: String? { "Your library is updating. Try removing this find again in a moment." }
}

@main
struct CommonThreadApp: App {
    var body: some Scene { WindowGroup { FindsAppRoot() } }
}

@MainActor
struct MymahFindsView: View {
    private enum Tab: Hashable { case library, search, profile }
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
    @State private var selectedSource: String?
    @State private var showsGrid = true
    @State private var discardingDraft: PendingCapture?

    private var sources: [String] { Array(Set(items.map(\.source))).sorted() }
    private var visibleItems: [SavedItem] { items.filter { selectedSource == nil || $0.source == selectedSource } }
    private var searchResults: [SavedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return items.filter { item in
            [item.title, item.note, item.selectedText, item.originalUrl, item.source]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            library.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(Tab.library)
            search.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            profile.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(Tab.profile)
        }
        .tint(NativeTheme.accent)
        .sheet(isPresented: $showingCapture, onDismiss: { Task { await refresh() } }) {
            CaptureForm(connection: connection) {
                selectedSource = nil
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
        }
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
                            if connection == nil {
                                Label("On this iPhone", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if !items.isEmpty {
                            Button { showsGrid.toggle() } label: {
                                Image(systemName: showsGrid ? "list.bullet" : "square.grid.2x2")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(showsGrid ? "Show as list" : "Show as grid")
                        }
                    }
                    feedback
                    if items.isEmpty {
                        LibraryEmptyState(symbol: "bookmark.fill", title: "A home for\nyour finds.", detail: "An idea. A lovely object. Something for later. Save your first link and make it yours.")
                        NativePrimaryButton(title: "Save your first link") {
                            showingCapture = true
                        }.disabled(busy)
                        if connection != nil {
                            Label("You can also share a link from another app.", systemImage: "square.and.arrow.up")
                                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    } else {
                        sourceFilters
                        savedItems(visibleItems, grid: showsGrid && !typeSize.isAccessibilitySize)
                        moreItemsButton
                    }
                    if busy { ProgressView("Updating your library").frame(maxWidth: .infinity).padding() }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(NativeTheme.bg)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCapture = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Save a link").accessibilityIdentifier("addSave")
                        .disabled(busy)
                }
            }
            .refreshable { await refresh() }
        }.id(accountGeneration)
    }

    private var sourceFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceButton(nil, label: "All finds")
                ForEach(sources, id: \.self) { source in sourceButton(source, label: source.capitalized) }
            }
        }
    }
    private func sourceButton(_ source: String?, label: String) -> some View {
        Button { selectedSource = source } label: {
            Text(label).font(.subheadline.weight(.semibold)).padding(.horizontal, 17).padding(.vertical, 11)
                .foregroundStyle(selectedSource == source ? NativeTheme.bg : Color.primary)
                .background(selectedSource == source ? Color.primary : NativeTheme.surface, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selectedSource == source ? .isSelected : [])
    }

    private var search: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    feedback
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LibraryEmptyState(symbol: "magnifyingglass", title: "Find that\nthing again.", detail: "A word from your note, the name of a website, or the title you remember.")
                    } else if searchResults.isEmpty {
                        LibraryEmptyState(symbol: "text.magnifyingglass", title: "No matches yet.", detail: "Try a different word or phrase in your saved content.")
                    } else {
                        Text("\(searchResults.count) \(searchResults.count == 1 ? "find" : "finds")")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        savedItems(searchResults, grid: false)
                    }
                    if nextOffset != nil {
                        Text("Searching \(items.count) loaded saves. Include older finds by loading more.")
                            .font(.footnote).foregroundStyle(.secondary)
                        moreItemsButton
                    }
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                }.padding(20)
            }
            .background(NativeTheme.bg).navigationTitle("Search")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library")
            .refreshable { await refresh() }
        }.id(accountGeneration)
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
            SavedContentView(item: item, stillSaved: items.contains { $0.id == item.id }, localOnly: connection == nil) { id, key in
                try await removeSave(id, key: key)
            }
        } label: { SavedContentCard(item: item, compact: !grid) }
        .buttonStyle(.plain).accessibilityIdentifier("savedItem-\(item.id)")
    }

    private var profile: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "bookmark.fill").font(.title2).foregroundStyle(NativeTheme.accent)
                            .frame(width: 60, height: 60).background(NativeTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Mymah Finds").font(.title2.bold())
                            Text("All the things you come back to.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                if let connection {
                    Section("Your library") {
                        LabeledContent("Account", value: connection.accountId)
                        LabeledContent("Connection", value: connection.baseURL.host ?? connection.baseURL.absoluteString)
                        LabeledContent("Loaded finds", value: String(items.count))
                    }
                } else {
                    Section("On this iPhone") {
                        Label("Local library", systemImage: "iphone")
                        LabeledContent("Saved finds", value: String(items.count))
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
                if connection != nil {
                    Section {
                        Button("Sign out", role: .destructive) { signOut() }.disabled(busy)
                    } footer: { Text("Pending saves remain on this device for this account. You can discard them above before signing out.") }
                }
            }
            .scrollContentBackground(.hidden).background(NativeTheme.bg).navigationTitle("Profile")
        }
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
            do {
                let saved = try await LocalLibrary.shared.collection()
                guard connection == nil, accountGeneration == generation else { return }
                items = saved; nextOffset = nil; pendingSaves = []; pendingErrors = [:]
                if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
                status = "Your finds are saved on this iPhone."
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
            items.removeAll { $0.id == id }
            if let selectedSource, !sources.contains(selectedSource) { self.selectedSource = nil }
            status = "Removed from this iPhone."
            return
        }
        let client = try environment.client(); try await environment.verify(client)
        _ = try await client.deleteSavedItem(id, key: key)
        guard sameAccount(environment, generation: generation) else { throw SetupError.accountChanged }
        items.removeAll { $0.id == id }
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
            nextOffset = nil; selectedSource = nil; searchText = ""; token = ""; errorMessage = nil; status = "Opening your local library."
            Task { await refresh() }
        } catch { errorMessage = error.localizedDescription }
    }
}
