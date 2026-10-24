import SwiftUI
import UIKit

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self { case .system: .unspecified; case .light: .light; case .dark: .dark }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, title
    var id: String { rawValue }
    var title: String {
        switch self { case .newest: "Newest first"; case .oldest: "Oldest first"; case .title: "Title A–Z" }
    }
}

enum LibraryScope: String, CaseIterable, Identifiable {
    case library, favorites, archived
    var id: String { rawValue }
    var title: String {
        switch self { case .library: "All finds"; case .favorites: "Favorites"; case .archived: "Archive" }
    }
    var symbol: String {
        switch self { case .library: "square.grid.2x2"; case .favorites: "heart"; case .archived: "archivebox" }
    }
}

enum LibraryFormat: String, CaseIterable, Identifiable {
    case all, images, links, voice, files, text
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .images: "photo"
        case .links: "link"
        case .voice: "waveform"
        case .files: "doc"
        case .text: "text.alignleft"
        }
    }
    var color: Color {
        switch self { case .all: .primary; case .images: .pink; case .links: .blue; case .voice: .purple; case .files: .orange; case .text: .teal }
    }
}

/// All explicit feedback respects the preference, including controls outside Profile.
@MainActor
enum FindsHaptics {
    static var enabled: Bool { (UserDefaults.standard.object(forKey: "finds.haptics") as? Bool) ?? true }
    static func selection() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
