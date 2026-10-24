import Foundation

/// Navigation only: links never carry content, credentials, or purchase actions.
enum MynahDeepLink {
    enum Destination: Equatable {
        case library(savedFindID: UUID?)
    }

    static func libraryURL(savedFindID: UUID? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "mynah"
        components.host = "library"
        if let savedFindID {
            components.queryItems = [URLQueryItem(name: "find", value: savedFindID.uuidString)]
        }
        // The components above are fixed identifiers and an optional UUID.
        return components.url!
    }

    static func destination(for url: URL) -> Destination? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "mynah", components.host?.lowercased() == "library",
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else { return nil }
        let values = components.queryItems ?? []
        guard values.count <= 1, values.allSatisfy({ $0.name == "find" }) else { return nil }
        if let rawID = values.first?.value {
            guard let id = UUID(uuidString: rawID) else { return nil }
            return .library(savedFindID: id)
        }
        guard values.isEmpty else { return nil }
        return .library(savedFindID: nil)
    }
}
