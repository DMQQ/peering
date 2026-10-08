import SwiftUI

/// The first screen the app shows, written for someone who has not decided yet. ``skip`` exists so a user who already knows what they want is one tap from the host list.
struct WelcomeFlow: View {
    var onFinish: () -> Void

    @State private var stage: Stage = .landing

    private enum Stage { case landing, tour }

    /// The landing leaves to the left, the way the tour's pages move. A cross-fade here read as no animation, since two thirds of the screen is identical before and after.
    private static let landingLeaves = AnyTransition.asymmetric(
        insertion: .opacity,
        removal: .move(edge: .leading).combined(with: .opacity)
    )
    private static let tourArrives = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .opacity
    )

    var body: some View {
        ZStack {
            switch stage {
            case .landing:
                LandingView(
                    onStart: { withAnimation(Motion.arrive) { stage = .tour } },
                    onSkip: onFinish
                )
                .transition(Self.landingLeaves)
            case .tour:
                OnboardingView(onFinish: onFinish)
                    .transition(Self.tourArrives)
            }
        }
        // Both stages are portrait; this stops the transition rotating halfway under a moving device.
        .preferredColorScheme(.dark)
    }
}

/// Opening and resting state of the landing's hero, kept apart from the Connect header's set: the two rest at different sizes, and one shared table would be a table of exceptions.
private enum LandingHero {
    static let restMark: CGFloat = 96
    static let openMark: CGFloat = 136
    static let restName: CGFloat = 42
    static let openName: CGFloat = 56
    static let restTracking: CGFloat = -1.5
    static let openTracking: CGFloat = -2.6
    static let restGap: CGFloat = 14
    static let openGap: CGFloat = 22
    /// Fixed while the hero moves: the mark and name change size on the way in, and a hero that resized would drag everything below it upward. Movement is an offset instead.
    static let height: CGFloat = 186
    static let topGap: CGFloat = 14
}

private struct LandingView: View {
    var onStart: () -> Void
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var arrived = false
    @State private var markZoom: CGFloat = 0
    @State private var titleReveal: CGFloat = 0
    @State private var heroTravel: CGFloat = 0
    @State private var heroRise: CGFloat = 0
    /// Measured once, while each is the width the centring wants (the state the hero is leaving).
    @State private var nameWidth: CGFloat = 0
    @State private var taglineWidth: CGFloat = 0
    /// Read from the layout, which an offset does not touch, so the opening position is a subtraction rather than a guess.
    @State private var blockTop: CGFloat = 0
    @State private var blockWidth: CGFloat = 0
    @State private var viewportMidY: CGFloat = 0
    @State private var entranceStarted = false

    /// Small on purpose: a claim per beat is most of a second of watching a list assemble.
    private static let stagger: Double = 0.055

    private struct ClaimLine {
        let icon: String
        let title: String
        let detail: String
    }

    /// Three claims; the rest are pages of the tour, where the same claims read better. What is left is what a visitor deciding needs: there is something to install on the Mac, the Mac is the full thing, and none of it goes through anybody's account.
    private static let claimLines: [ClaimLine] = [
        // First because the rest depends on it: this app does not find Macs by itself, something has to be running on the Mac.
        ClaimLine(
            icon: "macbook.and.iphone",
            title: String(localized: "Set it up once"),
            detail: String(localized: "Install Peering on your Mac, compare a six-digit code, and you are connected.")
        ),
        ClaimLine(
            icon: "macwindow",
            title: String(localized: "Your whole Mac, not a compromise"),
            detail: String(localized: "Open any display, app, window, or Space and switch between them without reconnecting.")
        ),
        // Kept here, not moved to the tour: it is a fact about the whole design, and the first thing someone handing their Mac to a phone asks.
        ClaimLine(
            icon: "lock.shield",
            title: String(localized: "Private by design"),
            detail: String(localized: "End-to-end encrypted, with no account and nothing for the relay to read.")
        )
    ]

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            ScrollView {
                Group {
                    if horizontalSizeClass == .regular {
                        regularWidthContent
                    } else {
                        compactWidthContent
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 48 : 18)
                .padding(.vertical, horizontalSizeClass == .regular ? 32 : 24)
                // Fills the viewport and centres the block, so a short page under a pinned button splits spare space above and below instead of pooling it in one gap.
                .containerRelativeFrame(.vertical, alignment: .center)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { midY in
                    viewportMidY = midY
                }
            }
            // Outside the scroll view so the way forward is on screen from the first frame; inside, both buttons sat below the fold.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
                    .frame(maxWidth: horizontalSizeClass == .regular ? 460 : .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalSizeClass == .regular ? 48 : 18)
                    .padding(.bottom, 18)
                    .padding(.top, 34)
                    .background {
                        // A fade rather than a bar, so the last claim dissolves under the buttons.
                        // Opaque from 40% down: `ignoresSafeArea` takes the gradient to the physical bottom, below the buttons, so a still-fading gradient at the last button let the page show through.
                        LinearGradient(
                            stops: [
                                .init(color: ColorPalette.backdrop.opacity(0), location: 0),
                                .init(color: ColorPalette.backdrop, location: 0.4)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    }
            }

            // Last in the stack so it sits over the scroll view and cannot scroll away.
            SkipButton(action: onSkip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .task { await arrive() }
    }

    private var compactWidthContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            hero
            claims
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            updateHeroGeometry(frame)
        }
    }

    private var regularWidthContent: some View {
        HStack(alignment: .center, spacing: 72) {
            hero
                .frame(maxWidth: 360)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    updateHeroGeometry(frame)
                }

            claims
                .frame(maxWidth: 600)
        }
        .frame(maxWidth: 1_032)
        .frame(maxWidth: .infinity)
    }

    private func updateHeroGeometry(_ frame: CGRect) {
        blockTop = frame.minY
        blockWidth = frame.width
    }

    /// Only the phone's single-column composition travels the hero to a corner; the iPad's side-by-side layout has none, and `centred(_:in:)` would centre in the narrow column rather than the screen.
    private var animatesHeroTravel: Bool { horizontalSizeClass != .regular }

    /// The entrance waits one frame at the starting value: setting a value in the same update as the first render animates from itself.
    private func arrive() async {
        guard !entranceStarted else { return }
        entranceStarted = true
        guard !reduceMotion else {
            markZoom = 1
            titleReveal = 1
            heroTravel = 1
            heroRise = 1
            arrived = true
            return
        }

        guard animatesHeroTravel else {
            // Rest sizes from the first frame, since nothing travels here; only the fade animates.
            heroTravel = 1
            heroRise = 1

            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(Motion.arrive) { markZoom = 1 }

            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(Motion.arrive) { titleReveal = 1 }

            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(Motion.arrive) { arrived = true }
            return
        }

        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(Motion.arrive) { markZoom = 1 }

        try? await Task.sleep(for: .milliseconds(520))
        withAnimation(Motion.arrive) { titleReveal = 1 }

        try? await Task.sleep(for: .milliseconds(600))
        withAnimation(Motion.travel) { heroTravel = 1 }
        withAnimation(Motion.rise) { heroRise = 1 }

        try? await Task.sleep(for: .milliseconds(620))
        withAnimation(Motion.arrive) { arrived = true }
    }

    private func entrance(delay: Double) -> Animation? {
        reduceMotion ? nil : Motion.arrive.delay(delay)
    }

    /// Alignment cannot be travelled through, so centring is an offset from a leading-aligned frame (as on the Connect header).
    private func centred(_ size: CGFloat, in width: CGFloat) -> CGFloat {
        (width - size) / 2 * (1 - heroTravel)
    }

    private var markSize: CGFloat {
        LandingHero.restMark + (LandingHero.openMark - LandingHero.restMark) * (1 - heroTravel)
    }

    private var markGap: CGFloat {
        LandingHero.restGap + (LandingHero.openGap - LandingHero.restGap) * (1 - heroTravel)
    }

    private var nameSize: CGFloat {
        LandingHero.restName + (LandingHero.openName - LandingHero.restName) * (1 - heroTravel)
    }

    private var nameTracking: CGFloat {
        LandingHero.restTracking + (LandingHero.openTracking - LandingHero.restTracking) * (1 - heroTravel)
    }

    /// Worked out from the block's laid-out top rather than measured off the mark, which carries the offset being solved for.
    private var heroStartOffset: CGFloat {
        guard viewportMidY > 0, blockTop > 0 else { return 0 }
        let markRestMidY = blockTop + LandingHero.topGap + LandingHero.restMark / 2
        return max(0, viewportMidY - markRestMidY) * (1 - heroRise)
    }

    /// Drawn from the `Pears` asset (the icon with its plate keyed out) rather than the app icon, whose rounded tile reads as a listing of apps.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(String(localized: "Pears"))
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .scaleEffect(markZoom)
                .opacity(markZoom)
                .padding(.bottom, markGap)
                .offset(x: animatesHeroTravel ? centred(markSize, in: blockWidth) : 0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Wordmark(size: nameSize, tracking: nameTracking)
                    .opacity(titleReveal)
                    .offset(
                        x: animatesHeroTravel ? centred(nameWidth, in: blockWidth) : 0,
                        y: 14 * (1 - titleReveal)
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                        guard heroTravel == 0 else { return }
                        nameWidth = measured
                    }

                // The whole opening statement, with nothing under it: a line of prose above the claims turns a first screen into something to get past.
                Text("Your Mac. Wherever you are.")
                    .font(.system(.title3).weight(.medium))
                    .foregroundStyle(.secondary)
                    .opacity(titleReveal)
                    .offset(
                        x: animatesHeroTravel ? centred(taglineWidth, in: blockWidth) : 0,
                        y: 10 * (1 - titleReveal)
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                        guard heroTravel == 0 else { return }
                        taglineWidth = measured
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: LandingHero.height, alignment: .topLeading)
        .padding(.top, LandingHero.topGap)
        .offset(y: animatesHeroTravel ? heroStartOffset : 0)
    }

    private var claims: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.claimLines.enumerated()), id: \.offset) { index, line in
                Claim(icon: line.icon, title: line.title, detail: line.detail)
                    .opacity(arrived ? 1 : 0)
                    .offset(y: arrived ? 0 : 14)
                    // Each a little after the last; the first waits for the name above it.
                    .animation(entrance(delay: 0.14 + Self.stagger * Double(index)), value: arrived)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Arrives with the last claim: shown from the first frame it read as a page that was simply there. The space is reserved in the bottom inset, so nothing moves as it fades up.
    private var actions: some View {
        WelcomePrimaryButton(title: String(localized: "See how it works"), action: onStart)
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 12)
            .animation(entrance(delay: 0.3), value: arrived)
    }
}

struct WelcomePrimaryButton: View {
    let title: String
    var action: () -> Void

    /// Taller and heavier than a stock control on purpose: at 44pt subheadline-semibold it read as a large link. Also applies to the paywall's buy button.
    private static let height: CGFloat = 54

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
        }
        .buttonStyle(WelcomeButtonStyle())
        // Swapping the title without animating keeps it a label change, not a button that shrinks and grows.
        .animation(nil, value: title)
    }
}

/// `.borderedProminent` eases its fill over 0.2s, which over white on near-black is almost nothing and reads as busy. This shrinks and hapticks immediately, then returns on a spring (the press lands; the release gives).
private struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ColorPalette.ink, in: Capsule())
            .foregroundStyle(ColorPalette.onInk)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.34, dampingFraction: 0.7),
                value: configuration.isPressed
            )
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in
                pressed
            }
    }
}

struct SkipButton: View {
    var action: () -> Void

    var body: some View {
        Button("Skip", action: action)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(RailButtonStyle(scale: 0.98))
            .padding(.horizontal, 18)
            .padding(.top, 6)
    }
}

private struct Claim: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .rowSurface()
    }
}

#Preview {
    WelcomeFlow(onFinish: {})
        .preferredColorScheme(.dark)
}
