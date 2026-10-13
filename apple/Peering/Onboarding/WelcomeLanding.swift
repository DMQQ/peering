import SwiftUI

/// The first screen, for someone who has not decided yet: the product itself above the fold, one line of what it does, and the three reasons it is safe to try hung around it as chips.
struct WelcomeLanding: View {
    var onStart: () -> Void
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var arrived = false

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            Group {
                if horizontalSizeClass == .regular {
                    HStack(alignment: .center, spacing: 64) {
                        phone.frame(maxWidth: 440)
                        copy.frame(maxWidth: 520)
                    }
                    .padding(.horizontal, 48)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        phone
                        copy
                    }
                    .padding(.horizontal, 22)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }

            SkipButton(action: onSkip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .task { await arrive() }
    }

    private var phone: some View {
        WelcomeHero()
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: horizontalSizeClass == .regular ? 560 : .infinity)
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 28)
            .scaleEffect(arrived ? 1 : 0.96)
            .animation(reduceMotion ? nil : Motion.arrive, value: arrived)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Mac. Wherever you are.")
                .font(DisplayFont.display(40))
                .tracking(-1.4)
                .foregroundStyle(ColorPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("See and control your Mac from this iPhone. A free Peering app on the Mac does the sharing, so you install it there once.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : 16)
        .animation(reduceMotion ? nil : Motion.arrive.delay(0.12), value: arrived)
    }

    private var actions: some View {
        WelcomePrimaryButton(title: String(localized: "See how it works"), action: onStart)
            .frame(maxWidth: horizontalSizeClass == .regular ? 460 : .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalSizeClass == .regular ? 48 : 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .background(ColorPalette.backdrop.opacity(0.92).ignoresSafeArea())
            .opacity(arrived ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.arrive.delay(0.24), value: arrived)
    }

    /// One frame at the starting value first: setting it in the same update as the first render animates from itself.
    private func arrive() async {
        guard !arrived else { return }
        try? await Task.sleep(for: .milliseconds(60))
        arrived = true
    }
}
