import SwiftUI

enum NativeTheme {
    static let bg = Color(.systemBackground)
    static let surface = Color(.secondarySystemBackground)
    static let accent = Color.blue
}

struct NativePrimaryButton: View {
    let title: String
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline.bold())
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .frame(maxWidth: .infinity).padding(.vertical, 19)
                .background(Color.primary.opacity(isEnabled ? 1 : 0.35), in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct FindsMark: View {
    var body: some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: 70, weight: .black))
            .rotationEffect(.degrees(-10))
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    Capsule().frame(width: 7, height: 5)
                    Capsule().frame(width: 7, height: 5)
                }.foregroundStyle(NativeTheme.bg).padding(.top, 22).rotationEffect(.degrees(-10))
            }
            .accessibilityHidden(true)
    }
}
