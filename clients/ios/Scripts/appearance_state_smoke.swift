import Foundation
import Observation

private final class ChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "AppearanceSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct AppearanceStateSmoke {
    @MainActor static func main() throws {
        let suite = "MynahAppearanceSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("light", forKey: AppAppearanceState.storageKey)
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppAppearanceState.storageKey] = "dark"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        var applied: [AppAppearance] = []
        let state = AppAppearanceState(defaults: defaults, domainName: suite) { applied.append($0) }
        try check(state.selection == .light, "Persistence must win over a stale UserDefaults argument-domain value")
        try check(applied == [.light], "Initial presentation must receive the persisted mode")
        for value in [AppAppearance.dark, .light, .system, .dark, .light] {
            let change = ChangeProbe()
            withObservationTracking { _ = state.selection } onChange: { change.mark() }
            state.select(value)
            try check(state.selection == value, "The shared UI value must change synchronously")
            try check(change.changed, "Selection must invalidate an observing SwiftUI view")
            try check(defaults.persistentDomain(forName: suite)?[AppAppearanceState.storageKey] as? String == value.rawValue,
                      "Every mode change must persist")
            try check(applied.last == value, "Share/window propagation must receive every selection immediately")
        }
        let reopened = AppAppearanceState(defaults: defaults, domainName: suite)
        try check(reopened.selection == .light, "Relaunch must restore the user’s latest choice")
        let launch = AppAppearanceState(defaults: defaults, domainName: suite, initial: .dark)
        launch.select(.light)
        try check(launch.selection == .light, "A one-time launch appearance must not lock the selector")
        state.select(.system)
        try check(applied.last == .system, "System must propagate a reset, not retain the forced mode")
        let count = applied.count
        state.applyToCurrentPresentation()
        try check(applied.count == count + 1 && applied.last == .system, "New/foreground presentations must inherit current mode")
        print("Appearance state smoke passed: persisted load, stale override isolation, observed light/dark/system transitions, immediate propagation, relaunch and one-time launch override")
    }
}
