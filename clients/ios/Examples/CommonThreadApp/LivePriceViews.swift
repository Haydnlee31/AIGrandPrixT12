import SwiftUI

struct LivePricePanel: View {
    let url: URL
    let title: String
    @State private var snapshot: LivePriceSnapshot?
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var retry = UUID()
    @State private var editingTarget = false
    @ObservedObject private var tracker = PriceTrackingController.shared
    private var watch: TrackedPrice? { tracker.watch(for: url) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Price check", systemImage: "tag").font(.headline.bold())
                Spacer()
                Button { retry = UUID() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .disabled(checking).accessibilityLabel("Check current Amazon price")
            }
            if checking { ProgressView("Checking Amazon…").font(.subheadline) }
            else if let snapshot { PriceSnapshotView(snapshot: snapshot) }
            else if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.secondary) }
            if let watch {
                HStack {
                    Label("Tracking price", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Edit") { editingTarget = true }
                }.font(.subheadline.weight(.semibold))
                if let target = watch.targetMinor, let currency = watch.currency {
                    Text("Target: \(PriceMoney.label(target, currency: currency))").font(.caption).foregroundStyle(.secondary)
                }
                PriceHistoryView(watch: watch)
            } else {
                Button { editingTarget = true } label: {
                    Label("Track price", systemImage: "bell.badge").font(.subheadline.bold())
                }.buttonStyle(.bordered).tint(.purple).disabled(tracker.updating)
            }
        }.padding(18).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            .task(id: url.absoluteString + retry.uuidString) {
                guard !Task.isCancelled else { return }
                checking = true; errorMessage = nil; snapshot = nil
                do {
                    let result = try await LivePriceService.check(url)
                    try Task.checkCancellation(); snapshot = result; checking = false
                } catch is CancellationError { return }
                catch { if !Task.isCancelled { errorMessage = error.localizedDescription; checking = false } }
                await tracker.refresh()
            }
            .sheet(isPresented: $editingTarget) {
                PriceTargetEditor(url: url, title: title, snapshot: snapshot ?? watch?.lastResult, existing: watch)
            }
    }
}

private struct PriceSnapshotView: View {
    let snapshot: LivePriceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.isAvailable, let price = snapshot.priceMinor, let currency = snapshot.currency {
                Text(PriceMoney.label(price, currency: currency)).font(.title.bold()).monospacedDigit()
                if let reference = snapshot.referencePriceMinor, reference > price,
                   let reduction = snapshot.discountPercent, reduction > 0, let label = snapshot.referenceLabel {
                    HStack(spacing: 8) {
                        Text("\(label) \(PriceMoney.label(reference, currency: currency))").strikethrough().foregroundStyle(.secondary)
                        Text("\(reduction)% below \(label)").fontWeight(.semibold).foregroundStyle(.green)
                    }.font(.caption)
                }
                Text("Item price · Shipping and eligibility checked on Amazon").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Price unavailable").font(.headline)
                Text(snapshot.message).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Checked \(Date(timeIntervalSince1970: snapshot.checkedAt).formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct PriceWatchListSection: View {
    @ObservedObject private var tracker = PriceTrackingController.shared
    @State private var selected: TrackedPrice?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !tracker.watches.isEmpty {
                HStack { Text("Price tracking").font(.title2.bold()); Spacer(); if tracker.updating { ProgressView().controlSize(.small) } }
                ForEach(tracker.watches) { watch in
                    Button { selected = watch } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: watch.targetReached == true ? "checkmark.seal.fill" : "tag")
                                .foregroundStyle(watch.targetReached == true ? .green : .purple)
                                .font(.title3).frame(width: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(watch.title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                                if let result = watch.lastResult, result.isAvailable, let amount = result.priceMinor, let currency = result.currency {
                                    Text(PriceMoney.label(amount, currency: currency)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    if watch.targetReached == true {
                                        Text("At your target").font(.caption).foregroundStyle(.green)
                                    } else if let drop = watch.priceDropMinor, drop > 0 {
                                        Text("Down \(PriceMoney.label(drop, currency: currency)) since the previous check").font(.caption).foregroundStyle(.green)
                                    }
                                } else { Text("Price unavailable at last check").font(.caption).foregroundStyle(.secondary) }
                                if let checked = watch.lastCheckedAt {
                                    Text("Checked \(Date(timeIntervalSince1970: checked).formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }.padding(16).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                }
                Text("Automatic checks · Updates appear here").font(.caption).foregroundStyle(.secondary)
            }
            if let error = tracker.errorMessage {
                HStack { Text(error).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Retry") { Task { await tracker.refresh() } }.font(.caption.bold()) }
            }
        }.task { await tracker.refresh() }
            .onChange(of: phase) { _, phase in if phase == .active { Task { await tracker.refresh() } } }
            .sheet(item: $selected) { watch in
                PriceWatchDetail(watchID: watch.id)
            }
    }
}

private struct PriceHistoryView: View {
    let watch: TrackedPrice
    var body: some View {
        if !watch.history.isEmpty {
            DisclosureGroup("Price history") {
                VStack(spacing: 10) {
                    ForEach(Array(watch.history.sorted { $0.checkedAt > $1.checkedAt }.prefix(12))) { point in
                        HStack {
                            Text(Date(timeIntervalSince1970: point.checkedAt), format: .dateTime.month(.abbreviated).day().hour().minute())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(PriceMoney.label(point.priceMinor, currency: point.currency)).monospacedDigit()
                        }.font(.caption)
                    }
                    Text("Observed item prices. Shipping excluded.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.subheadline).tint(.secondary)
        }
    }
}

private struct PriceWatchDetail: View {
    let watchID: String
    @ObservedObject private var tracker = PriceTrackingController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingTarget = false
    private var watch: TrackedPrice? { tracker.watches.first { $0.id == watchID } }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let watch {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(watch.title).font(.title2.bold())
                        if let snapshot = watch.lastResult { PriceSnapshotView(snapshot: snapshot) }
                        if let target = watch.targetMinor, let currency = watch.currency {
                            Label("Target \(PriceMoney.label(target, currency: currency))", systemImage: "scope").font(.subheadline.bold())
                        }
                        if watch.targetReached == true { Label("Your target price was reached", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        PriceHistoryView(watch: watch)
                        HStack {
                            Button("Check now") { Task { await tracker.check(watch) } }.buttonStyle(.borderedProminent).tint(.purple)
                            Button("Edit target") { editingTarget = true }.buttonStyle(.bordered)
                        }.disabled(tracker.updating)
                        if tracker.updating { ProgressView("Checking…") }
                        if let message = tracker.errorMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        if let url = URL(string: watch.productUrl) { Link("View on Amazon", destination: url).font(.headline) }
                        Button("Stop tracking", role: .destructive) {
                            Task { await tracker.remove(watch); if tracker.watches.allSatisfy({ $0.id != watchID }) { dismiss() } }
                        }.font(.subheadline).disabled(tracker.updating)
                    }.padding(24)
                }
            }.background(NativeTheme.bg).navigationTitle("Price tracking").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $editingTarget) {
                    if let watch, let url = URL(string: watch.productUrl) {
                        PriceTargetEditor(url: url, title: watch.title, snapshot: watch.lastResult, existing: watch)
                    }
                }
        }
    }
}

private struct PriceTargetEditor: View {
    let url: URL
    let title: String
    let snapshot: LivePriceSnapshot?
    let existing: TrackedPrice?
    @State private var target = 0.0
    @State private var useTarget = true
    @ObservedObject private var tracker = PriceTrackingController.shared
    @Environment(\.dismiss) private var dismiss
    private var currency: String? { snapshot?.isAvailable == true ? snapshot?.currency : existing?.currency }
    private var startingPrice: Int? { snapshot?.isAvailable == true ? snapshot?.priceMinor : existing?.targetMinor }
    private var step: Double { PriceMoney.targetStep(for: startingPrice ?? 100) }
    private var upper: Double { ceil(max(Double(startingPrice ?? 100) * 1.5, Double(existing?.targetMinor ?? 0), step * 2) / step) * step }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.title3.bold()).lineLimit(3)
                if let currency, let price = startingPrice, price > 0 {
                    Toggle("Set a target price", isOn: $useTarget).tint(.purple)
                    if useTarget {
                        Text(PriceMoney.label(Int(target), currency: currency)).font(.largeTitle.bold()).monospacedDigit()
                        Slider(value: $target, in: step...upper, step: step).tint(.purple)
                            .accessibilityLabel("Target item price").accessibilityValue(PriceMoney.label(Int(target), currency: currency))
                    }
                } else { Text("We’ll start recording prices when Amazon shows an accessible offer for this listing.").font(.subheadline).foregroundStyle(.secondary) }
                Text("Track this exact listing. Check Radar for price changes and target updates.").font(.footnote).foregroundStyle(.secondary)
                if let error = tracker.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                Spacer()
                NativePrimaryButton(title: tracker.updating ? "Saving…" : "Track price") {
                    Task {
                        if await tracker.save(url: url, title: title, target: useTarget && startingPrice != nil ? Int(target) : nil, currency: useTarget ? currency : nil) { dismiss() }
                    }
                }.disabled(tracker.updating)
            }.padding(24).background(NativeTheme.bg).navigationTitle("Track price").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(tracker.updating) } }
                .onAppear {
                    target = existing?.targetMinor.map(Double.init) ?? max(step, (Double(startingPrice ?? 100) * 0.9 / step).rounded() * step)
                    useTarget = existing == nil || existing?.targetMinor != nil
                }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(tracker.updating)
    }
}
