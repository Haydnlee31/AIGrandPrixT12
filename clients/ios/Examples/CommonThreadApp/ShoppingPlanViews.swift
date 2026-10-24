import SwiftUI
import Charts
import CommonThreadKit

private func planMoney(_ minor: Int, currency: String = "SGD") -> String {
    catalogCurrencyText(minor, currency: currency)
}

private func positiveMinorUnits(_ text: String) -> Int? {
    // NumberFormatter accepts numeric prefixes such as "12abc". Reject partial
    // parses and grouping; the current framework's editable budgets are SGD.
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
    guard normalized.range(of: #"\A[0-9]+(?:\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil,
          let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
          decimal > 0, decimal <= 100_000 else { return nil }
    let minor = NSDecimalNumber(decimal: decimal * 100)
    let integer = minor.intValue
    guard integer <= 10_000_000, minor.compare(NSDecimalNumber(value: integer)) == .orderedSame else { return nil }
    return integer
}

/// Optional framework flows. Presentation always discloses the backend's catalog/tracking mode.
struct FrameworkToolsView: View {
    let connection: SharedEnvironment
    @State private var capabilities: Capabilities?
    @State private var errorMessage: String?
    @State private var refreshID = UUID()
    var body: some View {
        List {
            if let capabilities {
                if capabilities.features["discovery"] == true {
                    Section {
                        NavigationLink { ShoppingPlansView(connection: connection, capabilities: capabilities) } label: { Label("Shopping plans", systemImage: "list.bullet.clipboard") }
                    } footer: { Text("Review the patterns in your saves, choose a direction and compare a shortlist.") }
                }
                Section {
                    NavigationLink { FrameworkCatalogView(connection: connection) } label: { Label("Browse catalog", systemImage: "bag") }
                    if capabilities.features["watches"] == true {
                        NavigationLink { PriceWatchesView(connection: connection, trackingMode: capabilities.dataModes["tracking"] ?? "unknown") } label: { Label("Price targets", systemImage: "tag") }
                    }
                    NavigationLink { ActivityInboxView(connection: connection, pushEnabled: capabilities.features["push_notifications"] == true) } label: { Label("Activity", systemImage: "bell") }
                }
                if capabilities.dataModes["catalog"] == "fixture" || capabilities.dataModes["tracking"] == "simulated" {
                    Section {
                        Label("Sample shopping tools", systemImage: "info.circle")
                        Text("This library’s shopping plans use a sample catalog. Price targets use simulated observations; they don’t monitor live stores or send push alerts.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Try again") { refreshID = UUID() }
            } else { ProgressView("Loading available tools") }
        }
        .navigationTitle("Shopping tools")
        .task(id: refreshID) {
            do { let api = try await connection.intelligenceClient(); let result = try await api.capabilities(); try Task.checkCancellation(); capabilities = result; errorMessage = nil }
            catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

private struct ShoppingPlansView: View {
    let connection: SharedEnvironment
    let capabilities: Capabilities
    @State private var hypotheses: [Hypothesis] = []
    @State private var sessions: [DiscoverySession] = []
    @State private var nextOffset: Int?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var selectedSession: DiscoverySession?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        List {
            if capabilities.dataModes["catalog"] == "fixture" {
                Section { Text("Try a shopping plan with sample desk-lighting products. These are example products, not live offers.").font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(hypotheses) { hypothesis in
                Section("A possible direction") {
                    Text(hypothesis.goal).font(.headline.bold())
                    Text("Based on \(hypothesis.independentSaves) independent saves. You decide whether it fits.").font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("Why this direction?") {
                        ForEach(hypothesis.evidence) { evidence in
                            NavigationLink { SavedEvidenceView(id: evidence.itemId, connection: connection) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(evidence.text).font(.subheadline)
                                    Text(evidence.origin.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    HStack {
                        Button("That fits") { feedback(hypothesis, action: .confirm) }
                        Spacer()
                        Menu("More") {
                            Button("Keep collecting") { feedback(hypothesis, action: .keepCollecting) }
                            Button("You misunderstood") { feedback(hypothesis, action: .misunderstood) }
                            Button("Dismiss direction") { feedback(hypothesis, action: .dismiss) }
                        }
                    }.disabled(busy)
                }
            }
            Section("Your plans") {
                Button("Start a shopping plan", systemImage: "plus") { start() }.disabled(busy)
                ForEach(sessions) { session in
                    NavigationLink { ShoppingPlanDetail(session: session, connection: connection, capabilities: capabilities) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shopping plan").font(.headline)
                            Text("\(session.stage.replacingOccurrences(of: "_", with: " ").capitalized) · \(Date(timeIntervalSince1970: session.createdAt).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let nextOffset { Button("Load more plans") { run { try await load(offset: nextOffset) } }.disabled(busy) }
            }
            if busy { ProgressView("Updating your plans") }
            if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.secondary) }
        }
        .navigationTitle("Shopping plans")
        .navigationDestination(isPresented: Binding(get: { selectedSession != nil }, set: { if !$0 { selectedSession = nil } })) {
            if let session = selectedSession { ShoppingPlanDetail(session: session, connection: connection, capabilities: capabilities) }
        }
        .task { do { try await load() } catch is CancellationError {} catch { errorMessage = error.localizedDescription } }
        .refreshable { do { try await load() } catch { errorMessage = error.localizedDescription } }
        .onDisappear { operation?.cancel() }
    }
    @MainActor private func load(offset: Int = 0) async throws {
        let api = try await connection.intelligenceClient()
        if offset == 0 { let result = try await api.hypotheses(); try Task.checkCancellation(); hypotheses = result.items }
        let result = try await api.discoveries(offset: offset)
        try Task.checkCancellation()
        if offset == 0 { sessions = result.items } else { let ids = Set(sessions.map(\.id)); sessions += result.items.filter { !ids.contains($0.id) } }
        nextOffset = result.nextOffset
    }
    @MainActor private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; errorMessage = nil
        operation = Task { @MainActor in defer { busy = false }; do { try await action() } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } } }
    }
    @MainActor private func feedback(_ hypothesis: Hypothesis, action: HypothesisFeedback) {
        run {
            let payload = ["action": action.rawValue], scope = "hypothesis:\(hypothesis.id)"
            let key = try await IntelligenceMutationKeys.shared.key(for: payload, scope: scope, connection: connection)
            let api = try await connection.intelligenceClient()
            _ = try await api.feedback(on: hypothesis.id, action: action, key: key)
            try await IntelligenceMutationKeys.shared.complete(payload, scope: scope, connection: connection)
            try await load()
        }
    }
    @MainActor private func start() {
        run {
            let payload = ["explicit": true], scope = "start-discovery"
            let key = try await IntelligenceMutationKeys.shared.key(for: payload, scope: scope, connection: connection)
            let api = try await connection.intelligenceClient()
            let result = try await api.startDiscovery(explicit: true, key: key)
            try await IntelligenceMutationKeys.shared.complete(payload, scope: scope, connection: connection)
            try Task.checkCancellation(); selectedSession = result
        }
    }
}

private struct ShoppingPlanDetail: View {
    @State var session: DiscoverySession
    let connection: SharedEnvironment
    let capabilities: Capabilities
    @State private var budget = ""
    @State private var width = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var pending: DiscoveryEvent?
    @State private var operation: Task<Void, Never>?
    @State private var watchProduct: Product?
    private var active: Bool { !["dismissed", "paused"].contains(session.stage) && !session.contextStale }
    var body: some View {
        Form {
            if session.contextStale { Section { Label("Your source saves changed. Start a new plan to use the latest context.", systemImage: "arrow.clockwise").foregroundStyle(.secondary) } }
            if capabilities.dataModes["catalog"] == "fixture" { Section { Text("Sample catalog · item prices exclude shipping. Purchases and live availability are not supported.").font(.footnote).foregroundStyle(.secondary) } }
            Section("Choose a feeling") {
                HStack {
                    Button("Warm & relaxed", systemImage: "sun.haze") { apply(.direction, value: .text("warm")) }
                    Spacer()
                    Button("Clear & focused", systemImage: "lightbulb") { apply(.direction, value: .text("focused")) }
                }
                Button("I want less clutter", systemImage: "rectangle.compress.vertical") { apply(.lessClutter) }
                if let direction = preferenceText("direction") { LabeledContent("Your direction", value: direction.capitalized) }
            }.disabled(!active || busy)
            Section("What should it fit?") {
                HStack { TextField("Item budget in SGD", text: $budget).keyboardType(.decimalPad); Button("Set") { if let amount = positiveMinorUnits(budget) { apply(.budget, value: .integer(amount)) } }.disabled(positiveMinorUnits(budget) == nil) }
                if case .integer(let value) = session.preferences["budget_minor"] { LabeledContent("Item budget", value: planMoney(value)) }
                HStack { TextField("Maximum width in cm", text: $width).keyboardType(.numberPad); Button("Set") { if let amount = Int(width), amount > 0, amount <= 10_000_000 { apply(.maxWidth, value: .integer(amount)) } }.disabled(Int(width).map { $0 <= 0 || $0 > 10_000_000 } ?? true) }
                if case .integer(let value) = session.preferences["max_width_cm"] {
                    LabeledContent("Maximum width", value: "\(value) cm")
                    Button("Remove width limit") { apply(.maxWidth) }
                }
                Button("Find a shortlist", systemImage: "line.3.horizontal.decrease") { apply(.retrieve) }
                    .disabled(session.preferences["budget_minor"] == nil || session.preferences["budget_minor"] == .null)
            }.disabled(!active || busy)
            if !session.products.isEmpty {
                Section("Compare your options") {
                    ForEach(session.products) { product in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(product.name).font(.headline.bold())
                            Text(product.variant).font(.subheadline).foregroundStyle(.secondary)
                            Text(planMoney(product.priceMinor, currency: product.currency)).font(.headline)
                            Text(product.explanation ?? product.tradeoff).font(.subheadline).foregroundStyle(.secondary)
                            LabeledContent("Width", value: "\(product.widthCm) cm").font(.caption)
                            if session.stage == "comparing" { Button("Choose this option") { apply(.choose, value: .text(product.variantId)) }.buttonStyle(.borderedProminent) }
                            Menu("Other options") {
                                Button("I already own this") { apply(.alreadyOwn, value: .text(product.variantId)) }
                                Button("Too expensive · change budget") { apply(.tooExpensive) }
                                if capabilities.features["watches"] == true, product.currency == "SGD" { Button("Save a price target") { watchProduct = product } }
                            }
                        }.padding(.vertical, 10).disabled(!active || busy)
                    }
                }
            }
            if session.stage == "ready" { Section { Label("Option chosen", systemImage: "checkmark.circle"); Text("Your choice is saved in this plan. No purchase has been made.").font(.footnote).foregroundStyle(.secondary) } }
            Section {
                if session.stage == "paused" { Button("Resume plan") { apply(.resume) } }
                else if session.stage != "dismissed" { Button("Pause plan") { apply(.pause) } }
                if session.stage != "dismissed" { Button("Dismiss plan", role: .destructive) { apply(.dismiss) } }
            }.disabled(busy)
            if busy { ProgressView("Saving your choice") }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary); if pending != nil { Button("Retry last change") { sendPending() }.disabled(busy) } } }
        }
        .navigationTitle("Your shopping plan").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $watchProduct) { product in CreatePriceTargetView(product: product, connection: connection, trackingMode: capabilities.dataModes["tracking"] ?? "unknown") }
        .onDisappear { operation?.cancel() }
    }
    private func preferenceText(_ key: String) -> String? { if case .string(let value) = session.preferences[key] { return value }; return nil }
    @MainActor private func apply(_ action: DiscoveryEvent.Action, value: DiscoveryEvent.Value? = nil) {
        guard !busy else { return }
        pending = DiscoveryEvent(expectedVersion: session.version, action: action, value: value)
        sendPending()
    }
    @MainActor private func sendPending() {
        guard !busy, let pending else { return }; busy = true; errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let scope = "discovery:\(session.id)"
                let key = try await IntelligenceMutationKeys.shared.key(for: pending, scope: scope, connection: connection)
                let api = try await connection.intelligenceClient()
                let result = try await api.apply(pending, to: session.id, key: key)
                try await IntelligenceMutationKeys.shared.complete(pending, scope: scope, connection: connection)
                try Task.checkCancellation(); session = result; self.pending = nil
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                if let conflict = error as? APIError, conflict.isVersionConflict, let latest = conflict.current {
                    session = latest; self.pending = nil
                    errorMessage = "This plan changed on another device. Review its latest state and choose again."
                } else if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct FrameworkCatalogView: View {
    let connection: SharedEnvironment
    @State private var catalog: Catalog?
    @State private var errorMessage: String?
    var body: some View {
        List {
            if let catalog {
                if catalog.dataMode == "fixture" { Section { Text("Sample catalog. These records do not represent current prices, stock or purchase links.").font(.footnote).foregroundStyle(.secondary) } }
                ForEach(catalog.items) { product in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(product.name).font(.headline.bold()); Text(product.variant).font(.subheadline).foregroundStyle(.secondary)
                        Text(planMoney(product.priceMinor, currency: product.currency)).font(.headline)
                        Text(product.tradeoff).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(product.widthCm) cm wide · \(product.style)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
            } else if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            else { ProgressView("Loading catalog") }
        }.navigationTitle("Catalog")
        .task { do { let api = try await connection.intelligenceClient(); let result = try await api.catalog(); try Task.checkCancellation(); catalog = result } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } } }
    }
}

private struct CreatePriceTargetView: View {
    let product: Product
    let connection: SharedEnvironment
    let trackingMode: String
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section(product.name) {
                    Text(product.variant)
                    TextField("Target item price in \(product.currency)", text: $target).keyboardType(.decimalPad)
                }
                Section { Text(trackingMode == "simulated" ? "This target uses simulated observations. It will not check live shops or send push alerts." : "A target records your preferred item price. Delivery and live monitoring depend on the connected service.").font(.footnote).foregroundStyle(.secondary) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            }
            .navigationTitle("Price target").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(busy || positiveMinorUnits(target) == nil) }
            }.interactiveDismissDisabled(busy)
        }.presentationDetents([.medium, .large]).onDisappear { operation?.cancel() }
    }
    @MainActor private func save() {
        guard !busy, product.currency == "SGD", let amount = positiveMinorUnits(target) else { return }; busy = true; errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let payload = WatchRequest(variantId: product.variantId, currency: product.currency, targetMinor: amount), scope = "create-watch"
                let key = try await IntelligenceMutationKeys.shared.key(for: payload, scope: scope, connection: connection)
                let api = try await connection.intelligenceClient()
                _ = try await api.createWatch(payload, key: key)
                try await IntelligenceMutationKeys.shared.complete(payload, scope: scope, connection: connection)
                try Task.checkCancellation(); dismiss()
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

struct CreateCatalogPriceTargetView: View {
    let product: CatalogRecord
    let connection: SharedEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section(product.title) {
                    Text(product.merchant.name ?? "Merchant")
                    Text("Observed item price: \(catalogCurrencyText(product.offer.priceMinor, currency: product.offer.currency))")
                    TextField("Alert at or below S$", text: $target).keyboardType(.decimalPad)
                }
                Section { Text("Checks use the merchant feed available to Mynah, not a live visit to the shop. Alerts appear in Activity. Prices exclude shipping; vouchers and membership discounts are not included.").font(.footnote).foregroundStyle(.secondary) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            }
            .navigationTitle("Track price").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Track") { save() }.disabled(busy || positiveMinorUnits(target) == nil) }
            }.interactiveDismissDisabled(busy)
        }.onDisappear { operation?.cancel() }
    }
    private func save() {
        guard !busy, let amount = positiveMinorUnits(target) else { return }
        busy = true; errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let payload = CatalogWatchRequest(sourceId: product.sourceId, recordId: product.sourceRecordId, targetMinor: amount)
                let scope = "create-catalog-watch"
                let key = try await IntelligenceMutationKeys.shared.key(for: payload, scope: scope, connection: connection)
                let api = try await connection.intelligenceClient()
                _ = try await api.createCatalogWatch(payload, key: key)
                try await IntelligenceMutationKeys.shared.complete(payload, scope: scope, connection: connection)
                try Task.checkCancellation(); dismiss()
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

struct PriceWatchesView: View {
    let connection: SharedEnvironment
    let trackingMode: String
    @State private var watches: [PriceWatch] = []
    @State private var nextOffset: Int?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        List {
            Section { Text("Merchant targets follow imported feed observations. Sample targets use simulated prices. Alerts appear in Activity; push delivery is not enabled.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(watches) { watch in
                NavigationLink { PriceTargetDetail(watch: watch, connection: connection, trackingMode: watch.dataMode ?? trackingMode) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(watch.catalog?.title ?? watch.variantId.replacingOccurrences(of: "-", with: " ").capitalized).font(.headline)
                        Text("Target \(planMoney(watch.targetMinor, currency: watch.currency)) · \(watch.enabled ? "Enabled" : "Paused")").font(.subheadline).foregroundStyle(.secondary)
                        Text(watch.catalog?.merchantName ?? "Simulated target").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !busy, watches.isEmpty, errorMessage == nil { ContentUnavailableView("No price targets yet", systemImage: "tag", description: Text("Track a supported merchant offer in Explore, or try a sample shopping plan.")) }
            if let nextOffset { Button("Load more") { load(offset: nextOffset) }.disabled(busy) }
            if busy { ProgressView("Loading targets") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary); Button("Try again") { load() } }
        }.navigationTitle("Price targets").onAppear { load() }.onDisappear { operation?.cancel() }
    }
    @MainActor private func load(offset: Int = 0) {
        guard !busy else { return }; busy = true; errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let api = try await connection.intelligenceClient()
                let result = try await api.watches(offset: offset); try Task.checkCancellation()
                if offset == 0 { watches = result.items } else { let ids = Set(watches.map(\.id)); watches += result.items.filter { !ids.contains($0.id) } }
                nextOffset = result.nextOffset
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

private struct PriceTargetDetail: View {
    @State var watch: PriceWatch
    let connection: SharedEnvironment
    let trackingMode: String
    @State private var target = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var history: PriceHistory?
    @State private var historyError: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Product", value: watch.catalog?.title ?? watch.variantId)
                LabeledContent("Target", value: planMoney(watch.targetMinor, currency: watch.currency))
                if let price = watch.lastPriceMinor { LabeledContent(trackingMode == "simulated" ? "Last simulated price" : "Last observed price", value: planMoney(price, currency: watch.currency)) }
                if let date = watch.lastCheckedAt { LabeledContent("Last observation", value: Date(timeIntervalSince1970: date).formatted()) }
            }
            if let history {
                Section("Observed price history") {
                    if history.items.count >= 2 {
                        Chart(history.items.sorted { $0.observedAt < $1.observedAt }) { point in
                            LineMark(x: .value("Observed", Date(timeIntervalSince1970: point.observedAt)), y: .value("SGD item price", Double(point.amountMinor) / 100))
                            PointMark(x: .value("Observed", Date(timeIntervalSince1970: point.observedAt)), y: .value("SGD item price", Double(point.amountMinor) / 100))
                        }.frame(height: 170).accessibilityLabel("Recorded item prices in Singapore dollars")
                    } else { Text("Collecting price history. A trend needs more than one observation.").foregroundStyle(.secondary) }
                    ForEach(history.items.prefix(5)) { point in
                        LabeledContent(Date(timeIntervalSince1970: point.observedAt).formatted(), value: planMoney(point.amountMinor, currency: history.currency))
                    }
                    Text(history.nextOffset == nil ? "Only prices recorded by Mynah are shown. Shipping is excluded." : "Chart shows the latest 100 observations. Shipping is excluded.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if watch.checkStatus == "waiting_for_current_offer" || watch.checkStatus == "identity_changed" {
                Section { Text(watch.checkStatus == "identity_changed" ? "The merchant product identity changed. This target will not alert on a different variant. Choose the correct product again in Explore." : "Waiting for a current merchant offer. The last recorded price may be out of date.").font(.footnote).foregroundStyle(.secondary) }
            }
            if let historyError { Text(historyError).font(.footnote).foregroundStyle(.secondary) }
            Section("Change target") {
                TextField("Target in \(watch.currency)", text: $target).keyboardType(.decimalPad)
                Button("Update target") { if let amount = positiveMinorUnits(target) { update(.init(targetMinor: amount)) } }.disabled(watch.currency != "SGD" || positiveMinorUnits(target) == nil || busy)
                Button(watch.enabled ? "Pause target" : "Resume target") { update(.init(enabled: !watch.enabled)) }.disabled(busy)
            }
            if trackingMode == "simulated" { Section { Text("Simulated observations only. This is not a live price alert.").font(.footnote).foregroundStyle(.secondary) } }
            if busy { ProgressView("Updating target") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
        }.navigationTitle("Price target").onDisappear { operation?.cancel() }
        .task(id: watch.ruleVersion) {
            do {
                let api = try await connection.intelligenceClient()
                let result = try await api.priceHistory(watch.id, limit: 100)
                try Task.checkCancellation(); history = result
            } catch is CancellationError {} catch { if !Task.isCancelled { historyError = error.localizedDescription } }
        }
    }
    @MainActor private func update(_ payload: WatchUpdate) {
        guard !busy else { return }; busy = true; errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let scope = "watch:\(watch.id)"
                let key = try await IntelligenceMutationKeys.shared.key(for: payload, scope: scope, connection: connection)
                let api = try await connection.intelligenceClient()
                let result = try await api.updateWatch(watch.id, update: payload, key: key)
                try await IntelligenceMutationKeys.shared.complete(payload, scope: scope, connection: connection)
                try Task.checkCancellation(); watch = result
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

private struct ActivityInboxView: View {
    let connection: SharedEnvironment
    let pushEnabled: Bool
    @State private var items: [AppNotification] = []
    @State private var nextOffset: Int?
    @State private var requestedOffset = 0
    @State private var errorMessage: String?
    @State private var busy = true
    @State private var refreshID = UUID()
    var body: some View {
        List {
            if !pushEnabled { Section { Text("Activity appears here when supplied by your shared library. Push notifications are not enabled.").font(.footnote).foregroundStyle(.secondary) } }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Label(item.message, systemImage: "bell")
                    Text(item.deliveryStatus.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            if busy { ProgressView("Loading activity") }
            if !busy, items.isEmpty, errorMessage == nil { ContentUnavailableView("All caught up", systemImage: "bell.badge", description: Text("New activity from your shared library will appear here.")) }
            if let nextOffset, !busy { Button("Load more") { requestedOffset = nextOffset } }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary); Button("Try again") { refreshID = UUID() } }
        }.navigationTitle("Activity")
        .refreshable { requestedOffset = 0; refreshID = UUID() }
        .task(id: "\(requestedOffset)|\(refreshID)") {
            busy = true; errorMessage = nil; defer { if !Task.isCancelled { busy = false } }
            do {
                let api = try await connection.intelligenceClient()
                let result = try await api.notifications(offset: requestedOffset); try Task.checkCancellation()
                if requestedOffset == 0 { items = result.items } else { let ids = Set(items.map(\.id)); items += result.items.filter { !ids.contains($0.id) } }
                nextOffset = result.nextOffset
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}
