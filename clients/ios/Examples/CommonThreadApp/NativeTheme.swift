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
    var size: CGFloat = 116

    var body: some View {
        Image("MynahMascot")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
