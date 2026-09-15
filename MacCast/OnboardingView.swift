import SwiftUI

/// Four pages, swiped, in the order the app asks things of you.
///
/// The order is the point rather than the count. Pair, choose, drive, leave — which is the
/// sequence a new user actually meets these, and each page is the answer to the question the
/// previous one raises. A tour that explained the joystick before it had explained what the
/// Mac's screen was doing on the phone would be a list of features rather than an introduction.
///
/// The buttons are outside the pages rather than in each one, so the way forward never moves and
/// the page dots are never something the user has to swipe back to find.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var index = 0

    private static let pages: [Page] = [
        Page(
            icon: "qrcode.viewfinder",
            title: "Pair once",
            body: """
                Your Mac shows a six-digit code. Type it, or scan the square beside it.

                If the two match, the devices pin each other. Every connection after this one is \
                silent.
                """
        ),
        Page(
            icon: "macwindow",
            title: "Share what you need",
            body: """
                A whole display, one running app, or a single window.

                The list is live, and includes apps you have not opened yet. Switch at any time \
                without dropping the connection.
                """
        ),
        Page(
            icon: "hand.point.up.left",
            title: "Drive it",
            body: """
                View & scroll puts your fingers on the Mac. Drag to move the pointer, tap to \
                click, two fingers to scroll.

                Drag & zoom moves only the picture, so nothing you do reaches the Mac by accident.
                """
        ),
        Page(
            icon: "arrow.triangle.2.circlepath",
            title: "Leave and come back",
            body: """
                Lock your phone and the session survives. Picture in Picture keeps the picture \
                up, and a Live Activity shows it on the Lock Screen.

                On a different network, Peering finds your Mac through the relay.
                """
        )
    ]

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { offset, page in
                        pageView(page).tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))

                actions
            }

            // Same corner as the landing's, so the two screens do not jump under a thumb that
            // has just learnt where it is.
            SkipButton(action: onFinish)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func pageView(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: page.icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(ColorPalette.ink)
                .frame(height: 56)

            Text(page.title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .tracking(-1)

            Text(page.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    /// The same pair of buttons the landing ends on, at the same distance from the bottom of the
    /// display — see ``WelcomeActions``. The padding here is the landing's padding; the two
    /// screens are a swipe apart and a button that moves between them reads as a mistake.
    private var actions: some View {
        WelcomePrimaryButton(
            title: isLast ? "Get started" : "Next",
            action: advance
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, 8)
    }

    private var isLast: Bool { index == Self.pages.count - 1 }

    private func advance() {
        guard !isLast else {
            onFinish()
            return
        }
        withAnimation(Motion.settle) { index += 1 }
    }

    private var light: some View {
        RadialGradient(
            colors: [.white.opacity(0.07), .clear],
            center: .top,
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }
}

#Preview {
    OnboardingView(onFinish: {})
        .preferredColorScheme(.dark)
}
