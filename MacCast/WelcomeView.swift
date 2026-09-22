import SwiftUI

/// The first thing the app ever shows, and the only screen in it written for someone who has
/// not decided yet whether they want it.
///
/// Two stages behind one flag. The landing is the claim; the tour behind it is the detail, and
/// only a user who asks for it gets it. Someone who is here because they already know what they
/// want is one tap from the host list — which is the whole reason ``skip`` exists rather than a
/// back button.
///
/// It sits *in front of* ``HostPickerView`` rather than replacing it. The picker's own header is
/// already a kind of landing — the name, the tagline, the drawing of the two devices — and
/// duplicating that here would make the second screen of the app look like the first one
/// arriving twice. This one leads with the mark and the claim; that one leads with what it can
/// currently see on your network.
struct WelcomeFlow: View {
    /// Set when the user is done, however they got there.
    var onFinish: () -> Void

    @State private var stage: Stage = .landing

    private enum Stage { case landing, tour }

    /// The landing leaving to the left, the way the tour's own pages move.
    ///
    /// This was a cross-fade, and a cross-fade between these two screens is very nearly no
    /// animation at all: both are the same near-black, both carry the same two buttons at the same
    /// distance from the bottom, and the only part of the picture that changes is the block in the
    /// middle. Measured against what the eye has to go on, two thirds of the screen is identical
    /// before and after, so what the user sees is the middle of the page being redrawn — which is
    /// how a screen that *has* an animation comes to be described as one that hasn't.
    ///
    /// A push answers the question the cross-fade left open: which way is forward. It is also the
    /// direction the tour already moves in — its pages are swiped leftwards — so the landing
    /// leaves the way a page does, and the tour arrives the way a page does.
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
        // Both stages are portrait. `ContentView` already pins everything that is not the remote
        // screen; this is only here so the transition between the two stages cannot halfway
        // rotate under a device that is being moved while the flow is on screen.
        .preferredColorScheme(.dark)
    }
}

/// The landing's opening state and its resting state, as the two ends of one journey.
///
/// The same shape as the Connect header's own set — see `Hero` in `HostPickerView` — because the
/// two are the same arrival, one screen apart: the mark opens large in the middle of the screen and
/// settles into its corner as what follows arrives under it. Keeping the numbers local rather than
/// sharing one table is deliberate. The two rest at different sizes for good reasons (this one is
/// the first thing anyone sees and the mark is the whole of it), and a single table parameterised
/// for both would be a table of exceptions.
private enum LandingHero {
    /// The mark's resting size, which is the size the asset is drawn at when the page is still.
    static let restMark: CGFloat = 96
    static let openMark: CGFloat = 136
    static let restName: CGFloat = 42
    static let openName: CGFloat = 56
    static let restTracking: CGFloat = -1.5
    static let openTracking: CGFloat = -2.6
    static let restGap: CGFloat = 14
    static let openGap: CGFloat = 22
    /// The hero's resting height, held fixed while it moves.
    ///
    /// Load-bearing, and the reason the claims under it do not shuffle: the mark shrinks and the
    /// name's point size changes on the way in, both of which are layout, and a hero that resized
    /// itself would drag everything below it upward as it landed. The movement is an offset from
    /// this frame instead. The Connect header pays the same price for the same reason.
    static let height: CGFloat = 186
    /// The hero's own top padding, which is also how far the mark sits below the top of the block
    /// when it is not being measured.
    static let topGap: CGFloat = 14
}

/// The hero, the claims, and the two ways out.
private struct LandingView: View {
    var onStart: () -> Void
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Whether the claims have arrived, which is the last of the four beats.
    @State private var arrived = false
    /// The hero's arrival, in the same four numbers the Connect screen uses: how far the mark has
    /// appeared, how far the name has followed it, and how far the pair has travelled left and up.
    /// Two of them are separate because they are separate curves — see ``Motion/travel``.
    @State private var markZoom: CGFloat = 0
    @State private var titleReveal: CGFloat = 0
    @State private var heroTravel: CGFloat = 0
    @State private var heroRise: CGFloat = 0
    /// Measured once, while each is the width the centring wants — the state the hero is leaving.
    /// See the same trick, and the same warning, on the Connect header.
    @State private var nameWidth: CGFloat = 0
    @State private var taglineWidth: CGFloat = 0
    /// Where the page's block is laid out, in screen coordinates, and where the middle of the
    /// screen is. Both are read from the *layout*, which an offset does not touch, so the opening
    /// position is a subtraction rather than a guess about how tall the claims will be.
    @State private var blockTop: CGFloat = 0
    @State private var blockWidth: CGFloat = 0
    @State private var viewportMidY: CGFloat = 0
    @State private var entranceStarted = false

    /// How long between one claim and the next.
    ///
    /// Small, and it has to be: seven of them at a tenth of a second each is most of a second of
    /// watching a list assemble itself, which is a thing to sit through rather than a thing to
    /// read. This is the whole difference between the page introducing itself and the page
    /// performing.
    private static let stagger: Double = 0.055

    /// What this does, in the order someone deciding would ask.
    ///
    /// Every line is checkable against the app, and the two that most often need correcting are
    /// answered here rather than only in the FAQ: there is a relay, and it is named as one; and
    /// the encryption is described as what it is — the two devices authenticating each other,
    /// not a promise about a server that cannot read what it carries anyway.
    private struct ClaimLine {
        let icon: String
        let title: String
        let detail: String
    }

    private static let claimLines: [ClaimLine] = [
        // First because it is the fact the rest of the page depends on, and the one a visitor is
        // most likely not to have: this is not an app that finds Macs by itself. Something has to
        // be running on the Mac, and until this line existed nothing on this screen said so:
        // the first mention was the picker's empty state, which is a screen they only reach after
        // deciding, and only after deciding that nothing had been found.
        ClaimLine(
            icon: "macbook.and.iphone",
            title: "Set it up once",
            detail: "Install Peering on your Mac, compare a six-digit code, and you are connected."
        ),
        ClaimLine(
            icon: "network",
            title: "Come back from anywhere",
            detail: "Peering remembers your Mac and finds it again, on your Wi-Fi or miles away."
        ),
        ClaimLine(
            icon: "macwindow",
            title: "Your whole Mac, not a compromise",
            detail: "Open any display, app, window, or Space and switch between them without reconnecting."
        ),
        ClaimLine(
            icon: "hand.point.up.left",
            title: "Control it like it is in front of you",
            detail: "Tap, type, scroll, zoom, use shortcuts, and move the pointer with precision."
        ),
        ClaimLine(
            icon: "lock.shield",
            title: "Private by design",
            detail: "End-to-end encrypted, with no account and nothing for the relay to read."
        ),
        // Beside "It stays with you" rather than among the control claims, because it is the same
        // kind of fact: something the app does for a user who is not looking at it. It used to be
        // the one behaviour nobody found out about, since a shell that stops for an answer gives
        // no sign of it anywhere but its own tab.
        ClaimLine(
            icon: "bell.badge",
            title: "Told when a shell is waiting",
            detail: "A build that finishes, a prompt for a password, a command that wants an answer: the Mac tells you, on the Lock Screen and with the app closed."
        ),
        ClaimLine(
            icon: "pip",
            title: "It stays with you",
            detail: "Keep the session alive with Picture in Picture, Live Activities, and widgets."
        )
    ]

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

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
                // Fills the viewport and centres the block inside it, which is the other half of
                // what was wrong with this screen: with the card gone the content came up short,
                // and a short page under a pinned button pools every spare point in one gap above
                // it. Centred, the same space is split above and below and reads as margin rather
                // than as something missing. Taller content still scrolls, unchanged.
                .containerRelativeFrame(.vertical, alignment: .center)
                // The middle of that viewport, which is where the hero starts from.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { midY in
                    viewportMidY = midY
                }
            }
            // Outside the scroll view, so the way forward is on screen from the first frame.
            // It was the last thing in the stack, which put both buttons below the fold on a
            // phone — a landing screen whose only exit has to be scrolled for is a landing
            // screen that reads as a wall.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
                    .frame(maxWidth: horizontalSizeClass == .regular ? 460 : .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalSizeClass == .regular ? 48 : 18)
                    .padding(.bottom, 18)
                    .padding(.top, 34)
                    .background {
                        // A fade rather than a bar. A material edge would put a visible line
                        // across a page that is one continuous surface; this lets the last
                        // claim dissolve under the buttons instead of being cut off by them.
                        //
                        // Opaque from 40% down rather than at the very bottom, and that is the
                        // fix for a gradient that ran past the buttons: `ignoresSafeArea` takes
                        // the gradient to the physical bottom of the display, which is below
                        // where the buttons end — so with the fade still going at the last
                        // button, the page showed through it. The stops put the solid part
                        // under everything the user can press.
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

            // Last in the stack, so it sits over the scroll view rather than in it. It must not
            // scroll away: the one thing it is for is being findable on the way in, by someone
            // who has already decided this is not what they wanted.
            SkipButton(action: onSkip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .task { await arrive() }
    }

    /// The phone composition, kept intact for compact iPad windows as well.
    private var compactWidthContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            hero
            claims
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            updateHeroGeometry(frame)
        }
    }

    /// A readable iPad composition: the identity holds one column and the proof points another.
    /// Extra width becomes margin instead of turning each claim into a full-screen strip.
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

    /// The page arriving, in the order it wants to be read: the mark, then the name, then the hero
    /// taking its place, then the claims one after another — the same four beats, on the same
    /// curves, as the Connect header, because it is the same arrival seen from the other side.
    ///
    /// A beat of delay first, and not decoration. Setting a value in the same update as the view's
    /// first render animates *from* the value it already has — the page simply appears, and the
    /// code that looks like an entrance does nothing at all. It wants one frame on screen at the
    /// starting value before anything moves.
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

    /// How far something has to move to sit in the middle of the block's width, less the part of
    /// that journey the hero has already made. The Connect header's rule, for its reason: alignment
    /// cannot be travelled through, so the centring is an offset from a leading-aligned frame.
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

    /// Where the mark's middle sits when the page is still, and so how far down the hero has to be
    /// drawn for it to open in the middle of the screen instead.
    ///
    /// Worked out from the block's laid-out top rather than measured off the mark, because the mark
    /// carries the offset being solved for: measuring it would be asking it where it would be if it
    /// were not where it is. The two inputs are layout, and layout is the same on the first frame
    /// as on the last.
    private var heroStartOffset: CGFloat {
        guard viewportMidY > 0, blockTop > 0 else { return 0 }
        let markRestMidY = blockTop + LandingHero.topGap + LandingHero.restMark / 2
        return max(0, viewportMidY - markRestMidY) * (1 - heroRise)
    }

    /// The mark, the name, and the one sentence the whole app exists to make true.
    ///
    /// The artwork is the icon's two pears with the icon's own background lifted out — see the
    /// `Pears` asset, which is that PNG with the plate keyed to transparency. Drawn rather than
    /// presented as the app icon, because a rounded-square tile is what an icon looks like in a
    /// place that is *listing* apps, and this screen is not one of those.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("Pears")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .scaleEffect(markZoom)
                .opacity(markZoom)
                .padding(.bottom, markGap)
                .offset(x: centred(markSize, in: blockWidth))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                // The same wordmark the Connect screen shows, light and all. One name for the app
                // rather than a rounded one on the way in and a serif one once you are past it —
                // and the same sign, so the second screen reads as somewhere you have already been.
                Wordmark(size: nameSize, tracking: nameTracking)
                    .opacity(titleReveal)
                    .offset(
                        x: centred(nameWidth, in: blockWidth),
                        y: 14 * (1 - titleReveal)
                    )
                    // Measured while it is still, and only while it is, for the reason the Connect
                    // header gives: what the centring wants is the width of the state being left.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                        guard heroTravel == 0 else { return }
                        nameWidth = measured
                    }

                // The whole opening statement, and there is deliberately nothing else under it.
                // A sentence explaining what the app is used to sit here; it said what this line
                // already says, and two lines of prose above a list of claims is how a first
                // screen turns into something to get past rather than something to read.
                Text("Your Mac. Wherever you are.")
                    .font(.system(.title3).weight(.medium))
                    .foregroundStyle(.secondary)
                    .opacity(titleReveal)
                    .offset(
                        x: centred(taglineWidth, in: blockWidth),
                        y: 10 * (1 - titleReveal)
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                        guard heroTravel == 0 else { return }
                        taglineWidth = measured
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The resting height, whatever the hero is doing on its way there — see `LandingHero.height`.
        .frame(height: LandingHero.height, alignment: .topLeading)
        .padding(.top, LandingHero.topGap)
        .offset(y: heroStartOffset)
    }

    /// What it does, in the order someone deciding would ask.
    ///
    /// Every line is checkable against the app, and the two that most often need correcting are
    /// answered here rather than only in the FAQ: there is a relay, and it is named as one; and
    /// the encryption is described as what it is — the two devices authenticating each other,
    /// not a promise about a server that cannot read what it carries anyway.
    private var claims: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.claimLines.enumerated()), id: \.offset) { index, line in
                Claim(icon: line.icon, title: line.title, detail: line.detail)
                    .opacity(arrived ? 1 : 0)
                    .offset(y: arrived ? 0 : 14)
                    // Each one a little after the last, so the list arrives in the order it asks
                    // to be read rather than all at once. The first waits for the name above it.
                    .animation(entrance(delay: 0.14 + Self.stagger * Double(index)), value: arrived)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The way forward, which arrives last.
    ///
    /// It used to be on screen from the first frame, and that was deliberate — a landing whose
    /// only exit has to be waited for is a landing that reads as a wall. The *Skip* button still
    /// is: it has to be findable the moment somebody decides this is not for them. This one is a
    /// different thing. It is the end of the sentence the page is telling, and one that is
    /// already sitting there while the hero is still travelling answers a question the page has
    /// not finished asking — which is what made the whole arrival read as a page that was simply
    /// there rather than one that had introduced itself.
    ///
    /// So it comes in with the last claim. The space it occupies is reserved either way: it lives
    /// in the bottom inset, so nothing above it moves as it fades up.
    private var actions: some View {
        WelcomePrimaryButton(title: "See how it works", action: onStart)
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 12)
            .animation(entrance(delay: 0.3), value: arrived)
    }

    /// One soft light from the top, the same one the host picker uses. A single flat near-black
    /// reads as a hole rather than as a surface; this gives it a direction without adding a
    /// colour, which the palette does not have to spare.
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
}

/// The two ways out of the introduction: in, or past.
///
/// One view rather than one per stage, and that is not tidiness. The landing and the tour are
/// the same two buttons at the bottom of two screens a swipe apart, and as two copies they had
/// already come to rest at different heights and different sizes — the kind of thing that reads
/// as sloppiness the moment you swipe between them, without anyone being able to say why.
struct WelcomePrimaryButton: View {
    let title: String
    var action: () -> Void

    /// Taller and heavier than a stock control, and deliberately.
    ///
    /// This is the only filled button on the three screens that carry it, and on two of them it is
    /// the only way forward. At 44 points and subheadline-semibold it measured as a large *link* —
    /// the same weight as the sentences above it, in a box the size of a system control — which
    /// undersells the one thing on the page the user is meant to press. The height is Apple's own
    /// minimum for a comfortable target with margin over it; the weight is what makes it read as
    /// the primary action rather than as another label.
    ///
    /// It applies to the paywall's buy button too, which uses this same view and wants the same
    /// thing for the same reason.
    private static let height: CGFloat = 54

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
        }
        .buttonStyle(WelcomeButtonStyle())
        // The title changes under the finger between the last page and the one before it.
        // Swapping the word without animating it keeps that a label change rather than a button
        // that shrinks and grows as it is pressed.
        .animation(nil, value: title)
    }
}

/// The one filled button in the flow, with a press you can feel.
///
/// `.borderedProminent` was here, and it does have a press state — the fill eases a little darker
/// over the default 0.2 seconds. Over a white fill on a near-black screen that is a change of
/// almost nothing, and a fifth of a second is long enough that it reads as the button being busy
/// rather than as the button being held. The one control that advances the introduction has to
/// answer a thumb immediately, so it shrinks and it haptics, and both are over before the finger
/// is.
///
/// Released, it comes back on a spring with a little give in it. The shrink is deliberately not
/// springy — the press is a statement and wants to land — and the return is the opposite: it is
/// the button letting go, and a small overshoot there is the whole of what makes a tap feel like
/// it did something.
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

/// The way past the introduction.
///
/// Top-right and on its own, rather than tucked under the button it is an alternative to. At the
/// bottom the two sat two points apart and read as a pair of equal choices, which they are not:
/// one is the way in and the other is the door out. Up here it is clear of the primary action
/// and still exactly where iOS puts this.
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

/// One claim: a glyph, a phrase, and the sentence that makes it true.
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
