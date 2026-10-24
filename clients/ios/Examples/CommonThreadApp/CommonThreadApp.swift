import SwiftUI
import CommonThreadKit

@main
struct CommonThreadApp: App {
    var body: some Scene { WindowGroup { MymahFindsView() } }
}

struct MymahFindsView: View {
    private enum Tab: Hashable { case library, search, profile }
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .library
    @State private var apiURL = ""
    @State private var token = ""
    @State private var items: [SavedItem] = []
    @State private var pendingSaves: [PendingCapture] = []
    @State private var nextOffset: Int?
    @State private var connection: SharedEnvironment?
    @State private var status = "Connect to sync your library."
    @State private var busy = false
    @State private var showingCapture = false
    @State private var searchText = ""

    private var searchResults: [SavedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return items.filter { item in
            [item.title, item.note, item.selectedText, item.originalUrl]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            library.tabItem { Label("Library", systemImage: "books.vertical") }.tag(Tab.library)
            search.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            profile.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(Tab.profile)
        }
        .tint(Color(red: 0.15, green: 0.34, blue: 0.28))
        .sheet(isPresented: $showingCapture, onDismiss: { Task { await loadPending(); await refresh() } }) {
            if let connection { CaptureForm(connection: connection) { Task { await refresh() } } }
        }
        .task {
            if let saved = try? SharedEnvironment.read() {
                connection = saved; apiURL = saved.baseURL.absoluteString
                await sync()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && connection != nil && !busy { Task { await sync() } }
        }
    }

    private var library: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Section {
                        emptyState(symbol: "bookmark", title: "A home for your finds", detail: connection == nil
                            ? "Connect in Profile, then save the things you want to come back to."
                            : "Save a link here or share one to Mymah Finds from another app.")
                        if connection == nil { Button("Open Profile") { selectedTab = .profile } }
                        else { Button("Save your first link") { showingCapture = true }.disabled(busy) }
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            NavigationLink { SavedContentView(item: item) } label: { SavedContentRow(item: item) }
                        }
                    } header: { Text("Your saved content") }
                    moreItemsButton
                }
                if busy { Section { ProgressView("Updating your library") } }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCapture = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Save a link").disabled(connection == nil || busy)
                }
            }
            .refreshable { await refresh() }
        }
    }

    private var search: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section { emptyState(symbol: "magnifyingglass", title: "Find it again", detail: "Search the titles, notes, text and links in your library.") }
                } else if searchResults.isEmpty {
                    Section { emptyState(symbol: "magnifyingglass", title: "No matches yet", detail: "Try a different word or phrase.") }
                } else {
                    Section {
                        ForEach(searchResults) { item in
                            NavigationLink { SavedContentView(item: item) } label: { SavedContentRow(item: item) }
                        }
                    }
                }
                if nextOffset != nil {
                    Section {
                        Text("Searching \(items.count) loaded saves. Load more to include older finds.")
                            .font(.footnote).foregroundStyle(.secondary)
                        moreItemsButton
                    }
                }
                if busy { Section { ProgressView("Loading saved content") } }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library")
        }
    }

    private var profile: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mymah Finds").font(.title2.weight(.semibold))
                        Text("Keep what catches your eye.").foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                if let connection {
                    Section("Account") {
                        LabeledContent("Signed in as", value: connection.accountId)
                        LabeledContent("Connected server", value: connection.baseURL.host ?? connection.baseURL.absoluteString)
                    }
                } else {
                    Section {
                        TextField("Server URL", text: $apiURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect") { Task { await connect() } }.disabled(busy || token.isEmpty || apiURL.isEmpty)
                    } header: { Text("Connection") } footer: {
                        Text("Use your server address and access token to connect your saved content.")
                    }
                }
                Section("Sync") {
                    Text(status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("connectionStatus")
                    if busy { ProgressView() }
                    if connection != nil { Button("Sync library") { Task { await sync() } }.disabled(busy) }
                }
                if !pendingSaves.isEmpty {
                    Section {
                        ForEach(pendingSaves) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.request.title).font(.headline)
                                Text("Waiting to sync").font(.caption).foregroundStyle(.secondary)
                                Button("Discard pending save", role: .destructive) {
                                    Task {
                                        do { try await SharedEnvironment.outbox().remove(draft); await loadPending() }
                                        catch { status = error.localizedDescription }
                                    }
                                }.disabled(busy)
                            }
                        }
                    } header: { Text("Pending on this device") } footer: {
                        Text("These saves stay on this device until they sync. Retry with Sync library.")
                    }
                }
                if connection != nil {
                    Section {
                        Button("Sign out", role: .destructive) {
                            do {
                                try connection?.signOut(); connection = nil; items = []; pendingSaves = []
                                nextOffset = nil; searchText = ""; status = "Signed out."
                            } catch { status = error.localizedDescription }
                        }.disabled(busy)
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }

    @ViewBuilder private var moreItemsButton: some View {
        if let offset = nextOffset {
            Button("Load more saved items") { Task { await refresh(offset: offset) } }.disabled(busy)
        }
    }
    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 20)
    }
    private func connect() async {
        busy = true; defer { busy = false }
        do {
            guard let url = URL(string: apiURL) else { throw ClientError.invalidBaseURL }
            let suppliedToken = token
            let client = try CommonThreadClient(baseURL: url) { suppliedToken }
            let account = try await client.account()
            let environment = SharedEnvironment(baseURL: url, accountId: account.userId)
            try environment.store(token: suppliedToken); try environment.store()
            connection = environment; token = ""
            await loadPending()
            let page = try await client.collection(); items = page.items; nextOffset = page.nextOffset
            status = "Your library is connected."
        } catch { status = error.localizedDescription }
    }
    private func refresh(offset: Int = 0) async {
        guard let connection, !busy else { return }
        busy = true; defer { busy = false }
        await loadPending()
        do {
            let client = try connection.client(); try await connection.verify(client)
            let page = try await client.collection(offset: offset)
            if offset == 0 { items = page.items } else {
                let existing = Set(items.map(\.id)); items += page.items.filter { !existing.contains($0.id) }
            }
            nextOffset = page.nextOffset; status = "Your library is up to date."
        } catch { status = error.localizedDescription }
    }
    private func sync() async {
        guard let connection, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let client = try connection.client(); try await connection.verify(client)
            let outbox = try SharedEnvironment.outbox()
            var duplicateCount = 0
            for draft in try await outbox.pending(accountId: connection.accountId, baseURL: connection.baseURL) {
                let receipt = try await client.capture(draft.request, key: draft.key)
                if receipt.duplicate { duplicateCount += 1 }
                try await outbox.remove(draft)
            }
            let page = try await client.collection(); items = page.items; nextOffset = page.nextOffset
            status = duplicateCount > 0
                ? "Synced. \(duplicateCount) links were already in your library; their existing notes and text were kept."
                : "Your library is up to date."
        } catch { status = "Sync needs attention: \(error.localizedDescription)" }
        await loadPending()
    }
    private func loadPending() async {
        guard let connection else { pendingSaves = []; return }
        do { pendingSaves = try await SharedEnvironment.outbox().pending(accountId: connection.accountId, baseURL: connection.baseURL) }
        catch { status = "Pending saves could not be read: \(error.localizedDescription)" }
    }
}

private struct SavedContentRow: View {
    let item: SavedItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.headline).foregroundStyle(.primary)
            if !item.note.isEmpty { Text(item.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            Text(URL(string: item.originalUrl)?.host ?? item.source).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct SavedContentView: View {
    let item: SavedItem
    var body: some View {
        List {
            Section {
                Text(item.title).font(.title2.weight(.semibold))
                if let url = URL(string: item.originalUrl) {
                    Link(destination: url) { Label("Open original", systemImage: "arrow.up.right.square") }
                }
                Text(item.capturedDate, style: .date).font(.footnote).foregroundStyle(.secondary)
            }
            if !item.note.isEmpty { Section("Your note") { Text(item.note).textSelection(.enabled) } }
            if !item.selectedText.isEmpty { Section("Saved text") { Text(item.selectedText).textSelection(.enabled) } }
        }
        .navigationTitle("Saved item")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CaptureForm: View {
    let connection: SharedEnvironment
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var draft: PendingCapture?
    @State private var alreadySaved = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Public link", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(draft != nil)
                TextField("Title", text: $title).disabled(draft != nil)
                TextField("Add a note (optional)", text: $note, axis: .vertical).disabled(draft != nil)
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if let draft, !saving && !alreadySaved {
                    Button("Discard pending save and edit", role: .destructive) {
                        Task {
                            do { try await SharedEnvironment.outbox().remove(draft); self.draft = nil; errorMessage = nil }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                if saving { ProgressView() }
            }
            .navigationTitle("Save to Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(draft == nil ? "Save" : "Retry") { Task { await save() } }.disabled(saving || alreadySaved || url.isEmpty || title.isEmpty) }
            }
            .alert("Already saved", isPresented: $alreadySaved) {
                Button("Done") { dismiss() }
            } message: {
                Text("This link is already in your library. The existing note and text were kept; this save hasn’t added your changes.")
            }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let pending = draft ?? PendingCapture(request: CaptureRequest(url: url, title: title, note: note), accountId: connection.accountId, baseURL: connection.baseURL)
            let outbox = try SharedEnvironment.outbox(); try await outbox.enqueue(pending); draft = pending
            let client = try connection.client(); try await connection.verify(client)
            let receipt = try await client.capture(pending.request, key: pending.key)
            try await outbox.remove(pending); onSave()
            if receipt.duplicate { alreadySaved = true } else { dismiss() }
        } catch { errorMessage = "Pending on this device. Retry or close and sync later. \(error.localizedDescription)" }
    }
}
