import SwiftUI

struct FindsAppRoot: View {
    @AppStorage("finds.onboarding.complete") private var completed = false
    var body: some View {
        Group {
            if completed { MymahFindsView() }
            else { FindsOnboardingView { completed = true } }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") { completed = false }
            if ProcessInfo.processInfo.arguments.contains("-skipOnboarding") { completed = true }
        }
    }
}

/// Introduces capabilities that are backed by the shared framework.
struct FindsOnboardingView: View {
    var onComplete: () -> Void
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["A home for\nevery little find.", "Save the thing.\nKeep the feeling.", "Start small.\nMake it yours."]
    private let subtitles = [
        "Links, photos, and ideas, collected in one calm place. Welcome to Mymah Finds.",
        "What caught your eye? Add a note to keep the details that matter to you.",
        "Start with a link, photo, or idea. Your saves stay on this iPhone. You can connect a separate shared library later."
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if step > 0 {
                    Button { move(to: step - 1) } label: { Image(systemName: "chevron.left").font(.body.bold()).frame(width: 44, height: 44) }
                        .accessibilityLabel("Previous introduction")
                } else { Text("Mymah Finds").font(.headline.bold()) }
                Spacer()
                Button("Skip", action: onComplete).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("onboardingSkip")
            }.padding(.horizontal, 24)
            ScrollView {
                VStack(spacing: 28) {
                    artwork.frame(maxWidth: 360).frame(height: 310).accessibilityHidden(true)
                    VStack(spacing: 16) {
                        Text(titles[step]).font(.largeTitle.bold()).tracking(-1.1)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitles[step]).font(.body).foregroundStyle(.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }.multilineTextAlignment(.center)
                }.padding(.horizontal, 24).padding(.bottom, 25).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
            VStack(spacing: 24) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in Capsule().fill(index == step ? Color.primary : Color.secondary.opacity(0.2)).frame(width: index == step ? 24 : 6, height: 6) }
                }.accessibilityElement(children: .ignore).accessibilityLabel("Introduction \(step + 1) of 3")
                NativePrimaryButton(title: step == 0 ? "Get started" : step == 2 ? "Open my library" : "Continue") {
                    if step == 2 { onComplete() } else { move(to: step + 1) }
                }.accessibilityIdentifier("onboardingContinue")
            }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }.background(NativeTheme.bg)
    }
    @ViewBuilder private var artwork: some View {
        if step == 0 {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 1).frame(width: 278, height: 278)
                    Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 1).frame(width: 176, height: 176)
                    FindsMark()
                    orbitIcon("chair.lounge.fill", .orange).offset(x: -114, y: -76)
                    orbitIcon("lamp.table.fill", .purple).offset(x: 112, y: -58)
                    orbitIcon("safari.fill", .blue).offset(x: 0, y: -139)
                    orbitIcon("heart.fill", .pink).offset(x: -92, y: 100)
                    orbitIcon("link", .green).offset(x: 104, y: 99)
                }.position(center)
            }
        } else if step == 1 {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    orbitIcon("lamp.table.fill", .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A little inspiration").font(.headline.bold())
                        Text("Keep the original link").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Why are you saving this?").font(.headline.bold())
                Text("“That warm glow would be perfect next to my reading chair.”")
                    .font(.title3).foregroundStyle(.secondary)
                HStack { Text("Your words. Your context.").font(.caption); Spacer(); Image(systemName: "text.bubble.fill").foregroundStyle(.blue) }
            }.padding(24).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 30)).rotationEffect(.degrees(-3))
        } else {
            VStack(spacing: 20) {
                HStack(spacing: 22) {
                    orbitIcon("iphone", .blue)
                    orbitIcon("laptopcomputer", .purple)
                    orbitIcon("globe", .orange)
                }
                Image(systemName: "arrow.down").font(.title2).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 15) {
                    Label("Library", systemImage: "books.vertical.fill").font(.title2.bold())
                    Text("Save a link, photo, or idea. Keep the why. Find it again whenever you need it.").foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 28))
            }
        }
    }
    private func orbitIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(color)
            .frame(width: 60, height: 60).background(color.opacity(0.13), in: Circle())
    }
    private func move(to value: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = value }
    }
}

#Preview("Welcome") { FindsOnboardingView {} }
