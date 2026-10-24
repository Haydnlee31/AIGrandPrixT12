import Foundation
import Observation

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// One observable value drives the picker, SwiftUI and UIKit. UserDefaults is
/// persistence, never a second live source of truth for the selected mode.
@MainActor @Observable final class AppAppearanceState {
    private(set) var selection: AppAppearance
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let apply: (AppAppearance) -> Void
    static let storageKey = "finds.appearance"

    init(defaults: UserDefaults = .standard, domainName: String = Bundle.main.bundleIdentifier ?? "",
         initial: AppAppearance? = nil, apply: @escaping (AppAppearance) -> Void = { _ in }) {
        self.defaults = defaults
        self.apply = apply
        let persisted = defaults.persistentDomain(forName: domainName)?[Self.storageKey] as? String
        selection = initial ?? persisted.flatMap(AppAppearance.init(rawValue:)) ?? .system
        if initial != nil { defaults.set(selection.rawValue, forKey: Self.storageKey) }
        apply(selection)
    }

    func select(_ value: AppAppearance) {
        selection = value
        defaults.set(value.rawValue, forKey: Self.storageKey)
        apply(value)
    }

    func applyToCurrentPresentation() { apply(selection) }
}
