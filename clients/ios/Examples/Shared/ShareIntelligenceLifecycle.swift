import Foundation

/// The import/task boundary is independent of SwiftUI so canceled cold-start
/// schedules can be regression-checked without a phone or a paid AI request.
struct ShareIntelligenceRequest: Hashable {
    let context: String
    let ready: Bool
}

struct ShareIntelligenceLifecycle {
    private(set) var activeID: UUID?

    mutating func begin(_ request: ShareIntelligenceRequest, current: ShareIntelligenceRequest, cancelled: Bool) -> UUID? {
        guard !cancelled, request.ready, request == current else { return nil }
        let id = UUID(); activeID = id
        return id
    }

    func accepts(_ id: UUID, request: ShareIntelligenceRequest, current: ShareIntelligenceRequest, cancelled: Bool) -> Bool {
        !cancelled && activeID == id && request.ready && request == current
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}
