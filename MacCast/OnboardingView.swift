import MacCastKit
import StoreKit
import SwiftUI
import UIKit

/// Five pages, swiped, in the order the app asks things of you.
///
/// The order is the point rather than the count. Pair, choose, drive, leave, and what it costs —
/// which is the sequence a new user actually meets these, and each page is the answer to the
/// question the previous one raises. A tour that explained the joystick before it had explained
/// what the Mac's screen was doing on the phone would be a list of features rather than an
/// introduction, and one that asked for money before it had said what the money was for would be
/// an advertisement.
///
/// The buttons are outside the pages rather than in each one, so the way forward never moves and
/// the page dots are never something the user has to swipe back to find. The device at the top is
/// outside them for the same reason and one more: the tour is about a single thing, and one thing
/// does not leave the screen and come back every time a page turns.
struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(StoreManager.self) private var store

    @State private var index = 0
    /// How much room the pages leave above their words, which is how tall the device is drawn.
    ///
    /// Reported by the pages themselves rather than worked out here, because it is whatever is left
    /// over and only a page knows that. All five report the same number by construction — the title
    /// is one line on every page and the words are held to ``tallestWords`` on every page — so five
    /// views writing to one value is one answer rather than a race. When it was not true the race
    /// was the least of it: the device simply came out a different size on the fourth page.
    @State private var stageHeight: CGFloat = 0
    /// The tallest title-and-body block on any page, which is what every page's words are held to.
    ///
    /// Measured rather than written down — see ``bodyHeight`` for what the written-down version
    /// cost — and measured all at once rather than page by page, for the reason ``wordsRuler``
    /// gives. The largest ever seen rather than the last one seen, because it is written from more
    /// than one place and a plain assignment would be decided by whichever wrote last.
    @State private var tallestWords: CGFloat = 0
    /// Whether the current page's contents have arrived, or are on their way in.
    ///
    /// One flag for the whole tour rather than one per page, and it is only ever read by the page
    /// that is on screen — see ``pageView(_:at:)``. Off-screen pages answer `true` regardless, so
    /// that the page being swiped away never empties itself in front of the user on its way out.
    @State private var contentVisible = false
    /// The plan the last page is pointed at, or `nil` for the free one.
    ///
    /// **Opens on free, and that is the whole of what was wrong with this page.** It used to open
    /// on the dearest rung, so the last thing a five-page introduction said was "Continue with Pro,
    /// $99.99/yr", and the way out of it was a grey word above the button. The tour has just
    /// described an app the user has not used yet; asking first for a year of the top plan and
    /// treating free as a refusal is what made the page read as a pitch rather than a choice. The
    /// baseline is a row of its own now, and the row it opens on.
    @State private var chosen: StoreManager.Tier?

    /// How often this page offers to bill, which it does not ask about.
    ///
    /// The yearly, and it is not a silent default: the price on every row and on the button says
    /// "/ year", and the App Store's own sheet states the period and the amount again before
    /// anything is charged. The tour is five swipes long and is trying to get out of the way, so
    /// the period switch lives on the paywall, which is the screen whose whole job is the
    /// comparison.
    private static let onboardingPeriod = BillingPeriod.yearly

    /// What the free row says, built from the number the relay actually meters.
    ///
    /// Read off ``RelayPlan`` for the reason every other allowance claim in the app is: "half an
    /// hour" typed onto a screen beside a server configured for fifteen minutes is the drift that
    /// turns a promise into a support email.
    private static var freeLine: String {
        "\(RelayPlan.free.allowanceSpelling.capitalized) of relay a day, on one Mac"
    }

    /// Six lines of subheadline on a 402-point-wide screen: the *floor* under a page's body, and
    /// not the height of it. See ``pageView(_:at:)`` for what the block above it is holding still.
    ///
    /// It used to be the answer rather than the floor — the belief being that six lines was the
    /// longest body any page has. It is not; the fourth page's is seven, which ran 24 points past
    /// the number that was meant to be holding it and left that one page's stage a different height
    /// from the rest. Left here as a floor so that the first layout pass, before anything has been
    /// measured, starts somewhere sane.
    private static let bodyHeight: CGFloat = 124

    private static let pages: [Page] = [
        Page(
            content: .feature(icon: "wifi", screenshot: "AppConnect"),
            title: "Pair once",
            body: """
                Choose your Mac from Nearby on the same network, or pair from another network \
                with the ID under Devices. Someone must be at the Mac to read out the six digits.

                After that, the relay finds your Mac from other networks without pairing again.
                """
        ),
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppSources"),
            title: "Share what you need",
            body: """
                A whole display, one running app, or a single window.

                The list is live, and includes apps you have not opened yet. Switch at any time \
                without dropping the connection.
                """
        ),
        Page(
            content: .feature(icon: "hand.point.up.left", screenshot: "AppControls"),
            title: "Drive it",
            body: """
                Control & zoom puts your fingers on the Mac. Drag and tap to control it, pinch \
                to zoom, then use two fingers to move around the enlarged picture.

                Switch to Observe when you want to inspect the picture without sending input.
                """
        ),
        Page(
            content: .feature(icon: "arrow.triangle.2.circlepath", screenshot: "AppPictureInPicture"),
            title: "Leave and come back",
            body: """
                Lock your phone and the session survives. Picture in Picture keeps the picture \
                up, and a Live Activity shows it on the Lock Screen.

                Once paired, Peering can find your Mac through the relay when you are on a \
                different network. If the relay cannot be reached, the app says so separately \
                from a problem with your Mac.
                """
        ),
        Page(
            content: .plans,
            title: "Choose your plan",
            // One sentence, and the rows do the rest.
            //
            // **It used to be two paragraphs explaining the ladder**, over three rows that also
            // explained the ladder, in different words. The page was saying everything twice and
            // still leaving the reader to work out that the rows were steps rather than three
            // separate offers. What is left here is the one thing no row can say, which is that
            // the free plan is a real plan and not a trial.
            body: """
                Peering is free on your own network, for as long as you like. A plan is what \
                reaches your Mac when you are somewhere else, and every one of them includes \
                everything free has.
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
                        pageView(page, at: offset).tag(offset)
                    }
                }
                // The system's page dots are drawn by the page style and the page style draws
                // nothing else, so the indicator below is this view's own — see ``indicator`` for
                // why it is worth the four capsules it costs.
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background { wordsRuler }
                // The device, over the pages rather than in one of them, so that turning a page
                // moves the words and leaves the picture of the app where it is — see ``stage``.
                //
                // It keeps the whole of the swipe area with it. Drawn beside the pages instead of
                // over them, a frame that is not a page takes the top two thirds of the screen out
                // of the gesture, and the tour would only be swipeable by the two lines of text it
                // is about.
                .overlay(alignment: .top) { stage }

                indicator
                actions
            }

            // Same corner as the landing's, so the two screens do not jump under a thumb that
            // has just learnt where it is.
            SkipButton(action: onFinish)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .onAppear(perform: revealContent)
    }

    private func pageView(_ page: Page, at offset: Int) -> some View {
        // The page being looked at animates; every other page is simply in place, so that the one
        // leaving during a button-led change keeps its contents while it slides out.
        let shown = offset == index ? contentVisible : true

        return VStack(alignment: .leading, spacing: 18) {
            // The stage: everything above the title, and as tall as the page can spare.
            //
            // Empty on every page, and reserved on every page anyway. Reserved because it is the
            // device's box, and the device is drawn once over the top of all five — a page is the
            // only thing that knows how much room is left after its own words, and the alternative
            // is working it out from the outside, which means knowing how tall the words will be
            // before they have been laid out. Empty because what goes in it is not the page's
            // business any more.
            //
            // All five boxes are the same height, which is what makes one device sized from one of
            // them the right device for all of them. That is not luck and it is not this view's
            // doing: it follows from the words below being held to ``tallestWords``, and it is the
            // whole reason they are.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    stageHeight = height
                }

            // The words, as one block held to one height on every page.
            //
            // Held because the stage above them takes whatever is left: without it the shortest
            // page's title sits a line lower than the tallest page's, and swiping the tour moves
            // the heading up and down by the difference. A minimum rather than a fixed height, so
            // a longer body — the reader's own text size, in the end — grows the text instead of
            // being cut off by it.
            //
            // Now it holds for a second reason, and the stronger one: the stage above is not just
            // the title's position any more, it is the box the one device is drawn in, so a page
            // whose words ran past this would make the device on that page a size of its own.
            // Which is what it did — see ``bodyHeight`` and ``wordsRuler``.
            VStack(alignment: .leading, spacing: 18) {
                Text(page.title)
                    .font(DisplayFont.display(.largeTitle))
                    .tracking(-1)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 14)
                    .animation(motion(delay: 0.09), value: shown)

                Text(page.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 18)
                    .animation(motion(delay: 0.16), value: shown)
            }
            .frame(minHeight: max(Self.bodyHeight, tallestWords), alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    // MARK: - The stage

    /// All five pages' words, laid out at once and thrown away, so that the tallest of them can
    /// size every page's words block.
    ///
    /// This is what makes the device one device. Every page holds its words to the tallest block any
    /// page has, and the tallest block is a fact about the whole tour — which the pager will not
    /// tell you, because a page style `TabView` builds the page you are on and its neighbours and
    /// no further. Measuring the pages as they are visited is measuring them one at a time: the
    /// number grows every time the tour turns and the device shrinks with it, which looks exactly
    /// like a device that is a different size on every page, and was. Five blocks in one stack is
    /// the whole answer on the first frame, without waiting for the fourth page to be built.
    ///
    /// It is a background rather than a member of the layout, so it costs the screen nothing but the
    /// measurement, and it is hidden rather than removed because a view that is not laid out has no
    /// height to report.
    private var wordsRuler: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.pages.enumerated()), id: \.offset) { _, page in
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.title)
                        .font(DisplayFont.display(.largeTitle))
                        .tracking(-1)

                    Text(page.body)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The pages' own padding, so that every body here wraps at the width it wraps at there.
        .padding(.horizontal, 22)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            tallestWords = max(tallestWords, height)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// The room above the words, holding one device for the whole tour.
    ///
    /// This used to be a page's own business — five pages, five frames — and five frames is what it
    /// looked like: pressing Next slid one phone off the left of the screen while another slid in
    /// from the right, shrinking as it came, so the object the tour is about left and returned on
    /// every page. A device that does that is not one device. Drawn here instead, once, and what
    /// moves between pages is what it is holding.
    ///
    /// The last page has nothing to hold, and takes the device away rather than filling it with
    /// plan rows: the three plans are the page's content, and content inside a phone would read as
    /// a picture of a screen rather than as something to press. It fades rather than sliding, so
    /// that the page that ends the tour is the one page where the frame is not asked to travel.
    @ViewBuilder
    private var stage: some View {
        ZStack {
            if isLast {
                plans
                    .transition(.opacity)
            } else {
                PhoneStage {
                    // Keyed by the page so the picture inside the frame cross-dissolves as the
                    // words slide. One frame that swaps its contents reads as one device; one
                    // frame whose contents change instantly reads as a cut between two clips.
                    screen(for: index)
                        .id(index)
                        .transition(.opacity)
                }
                // The device is not a page and has no gestures of its own, so the swipe reaches
                // the pages underneath it.
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(height: stageHeight)
        .padding(.horizontal, 22)
        .animation(.easeInOut(duration: 0.34), value: index)
    }

    /// What the device is holding while a given page is on screen.
    ///
    /// The frame is the constant and this is the variable, which is the same arrangement the file
    /// used to describe from the other end: the shape of the app is the same from the first page to
    /// the last, and each page's picture lands inside it.
    @ViewBuilder
    private func screen(for offset: Int) -> some View {
        switch Self.pages[offset].content {
        case .feature(let icon, let screenshot):
            if let screenshot, UIImage(named: screenshot) != nil {
                Image(screenshot)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder(icon)
            }

        case .plans:
            // Never drawn — the last page takes the device away — but the switch has to answer.
            Color.black
        }
    }

    /// What the screen shows when its page has no screenshot yet.
    ///
    /// Naming a screenshot before taking it is the ordinary order to work in — the page is written,
    /// then the picture is made — so this is a state the tour is expected to pass through rather
    /// than a mistake. The frame still draws, so the page has the same shape as its neighbours, and
    /// the glyph says which page is waiting for its picture.
    private func placeholder(_ symbol: String) -> some View {
        ZStack {
            Color.black

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.13), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 62
                    )
                )

            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ColorPalette.ink)
        }
    }

    /// The three plans, as compactly as they can be told apart.
    ///
    /// Rows rather than cards with the full feature lists, because this is not the screen that
    /// sells them — it is the page that says there is something to decide before the introduction
    /// is over, at the one moment the user has just been told what the app does. The comparison is
    /// one tap away and is where the detail belongs; a page of three feature lists inside a swipe
    /// is a page nobody reads, on a screen that is trying to be finished with.
    @ViewBuilder
    private var plans: some View {
        if store.isPro {
            // Somebody who has already paid, looking at the tour again from Settings. There is
            // nothing to sell them, so the page states rather than asks.
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(ColorPalette.accent)

                Text("You are on Pro")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)

                Text("Every Mac, relay without a limit, and every update from here on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
        } else if store.products.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(ColorPalette.ink)
                Text(store.productsUnavailable
                     ? "The App Store could not be reached. You can choose a plan later in Settings."
                     : "Loading plans…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
        } else {
            VStack(spacing: 8) {
                // Free first, because it is the floor the other three are measured from rather than
                // a fourth thing on offer. Without it the page listed three products and left the
                // reader to work out what they were an upgrade *from*, which is the sentence the
                // rows above used to try to say in prose.
                PlanChoice(
                    name: "Free",
                    line: Self.freeLine,
                    price: nil,
                    recommended: false,
                    selected: chosen == nil,
                    select: { chosen = nil }
                )

                ForEach(StoreManager.Tier.allCases) { tier in
                    PlanChoice(
                        name: tier.name,
                        // One line each, opening with the relay allowance on all three so the rows
                        // read as a ladder. A tagline that led with something else made the three
                        // cards three unrelated claims, and the reader had to reconstruct the
                        // order from them.
                        line: tier.tagline,
                        // The yearly, always, on this page: it is four rows in a swipe rather than
                        // the comparison screen, and a period switch here would be a second
                        // decision inside the one screen that is trying to be finished with. The
                        // paywall is one tap away for anyone who wants the monthly, and both prices
                        // are on the App Store's own sheet either way.
                        price: store.priceLabel(for: tier, period: Self.onboardingPeriod),
                        recommended: tier.isRecommended,
                        selected: chosen == tier,
                        select: { chosen = tier }
                    )
                }
            }
            .animation(Motion.tap, value: chosen)
        }
    }

    private func motion(delay: Double) -> Animation? {
        reduceMotion ? nil : Motion.arrive.delay(delay)
    }

    /// Five capsules, and the one you are on is the long one.
    ///
    /// The page style's dots say how many pages there are and where you are, in the same shape
    /// twice: four identical circles, one of them filled. A capsule that grows says where you are
    /// in the *length* of the thing that moved, and it says it as a movement — pressing Next turns
    /// the pill back into a dot and stretches the next one out, which is the only motion on this
    /// screen that belongs to the change between pages rather than to a page.
    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.pages.count, id: \.self) { page in
                Capsule()
                    .fill(page == index ? ColorPalette.ink : Color.white.opacity(0.22))
                    .frame(width: page == index ? 24 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: index)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .accessibilityHidden(true)
    }

    /// Brings the current page's contents back in.
    ///
    /// The contents are taken away for one frame before being animated in, and the frame matters:
    /// setting the flag to `false` and `true` in the same update animates from `true` to `true`,
    /// which is no animation at all and is how this kind of stagger usually ends up doing nothing.
    private func revealContent() {
        guard !reduceMotion else {
            contentVisible = true
            return
        }
        contentVisible = false
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation { contentVisible = true }
        }
    }

    /// The button the landing ends on, at the same distance from the bottom of the display. The
    /// padding here is the landing's padding; the two screens are a swipe apart and a button that
    /// moves between them reads as a mistake.
    ///
    /// **The free way out used to be a second button above this one**, and it is gone because the
    /// free plan is a row on the last page now. That takes the reservation hack with it: the row
    /// had to hold its space on all five pages at zero opacity, or the primary button climbed the
    /// screen on the last one and climbed away from where the landing had left it. With one control
    /// in this stack the button sits at the landing's distance on every page, which is the number
    /// the two screens agree on, and it no longer costs the page above it any room to say so.
    private var actions: some View {
        VStack(spacing: 2) {
            WelcomePrimaryButton(
                title: primaryTitle,
                action: primaryAction
            )
            .disabled(store.isPurchasing)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, 8)
    }

    private var isLast: Bool { index == Self.pages.count - 1 }

    /// Whether the page on screen is offering a plan, which is the last one and only while there
    /// is something left to buy.
    private var showsPlans: Bool { isLast && !store.isPro }

    /// The button's label, which is the price on the page that has one.
    ///
    /// The price belongs on the button rather than only on the rows above it: those say what each
    /// tier is, and this is the moment the money is decided, so it is the last place the number
    /// can be read before it is spent.
    private var primaryTitle: String {
        guard showsPlans else { return isLast ? "Get started" : "Next" }

        // Free chosen, which is how the page opens. The button then says what it does rather than
        // naming a price: it is the way into the app, and the three purchases above it are the
        // other way in.
        guard let chosen else { return "Start using Peering" }

        guard let price = store.compactPriceLabel(for: chosen, period: Self.onboardingPeriod)
        else { return "Continue" }

        if store.isPurchasing { return "Contacting the App Store…" }
        return "Continue with \(chosen.name) · \(price)"
    }

    private func primaryAction() {
        // No tier chosen is the free plan, and the free plan is not a purchase: it is the button
        // that finishes the introduction.
        guard showsPlans, let chosen,
              let product = store.product(for: chosen, period: Self.onboardingPeriod)
        else {
            advance()
            return
        }

        Task {
            await store.purchase(product)
            // Finishing is what a purchase is for. Anything else — cancelled, declined, pending
            // approval — leaves the page where it is, with the reason on it if the store gave one,
            // so the choice can be made again or declined properly with the button underneath.
            if store.isPro { onFinish() }
        }
    }

    /// Forward by the button, which is the one route into a new page that needs any help.
    ///
    /// A page swiped in has already been seen arriving — it moved, and it did it under the user's
    /// finger — so its contents are left alone. A page the button moves to arrives with the whole
    /// screen sliding sideways, and the contents coming up inside it afterwards is the difference
    /// between turning a page and watching the page that was already there be replaced.
    private func advance() {
        guard !isLast else {
            onFinish()
            return
        }
        revealContent()
        withAnimation(Motion.arrive) { index += 1 }
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

    /// One page of the tour: what it is about, and what it says.
    private struct Page {
        let content: Content
        let title: String
        let body: String

        /// What the page puts in the stage at the top.
        ///
        /// A type rather than a view so that the two kinds of page — the four that describe the app
        /// and the one that asks for money — are told apart by the same list, in the same order,
        /// with the same page dots, rather than by an index comparison somewhere in the body.
        enum Content {
            /// A page about something the app does. `screenshot` is `nil` until one has been taken,
            /// in which case the page shows its glyph.
            case feature(icon: String, screenshot: String? = nil)
            /// The last page: what there is to buy.
            case plans
        }
    }
}

/// The frame's numbers, outside the view because a generic type cannot hold static storage — and
/// named in one place, as the Connect header's are, because they are one decision about a shape.
private enum PhoneStageMetrics {
    /// The screenshot's own proportions. A frame that did not match them would letterbox or crop
    /// every image put inside it, which is the one thing a frame must not do.
    static var aspect: CGFloat { 603.0 / 1311.0 }

    /// The bezel, as a fraction of the screen it surrounds rather than as a number of points.
    ///
    /// The site's mockup is a fixed 310-point body with 10 points of padding, and this frame is
    /// derived from whatever height the stage can spare — so the same 10 points here was 4.8% of
    /// the picture at the size the tour actually draws it, against the 3.4% the site draws the
    /// identical device at. A fixed border in one place and a derived one in the other is two
    /// devices, and the fat one is the one nobody drew. This is the site's own ratio: its padding
    /// over the 290-point screen it pads.
    static let bezel: CGFloat = 10.0 / 290.0

    /// Corner as a fraction of the body's width, and of the screen's — the site's 46 and 37 points
    /// against its 310-point body and 290-point screen.
    static let bodyCorner: CGFloat = 0.148
    static let screenCorner: CGFloat = 0.128

    /// The device's own colour, and the hairline of light along its edge.
    ///
    /// It was white at 18% fading to 5%, which over this near-black backdrop is not a device — it
    /// is a bright band, and a bright band is what the eye measures when it decides how thick a
    /// frame is. That, more than the ten points, is what was making this look like a mount. An
    /// iPhone seen face on in a dark room is the opposite arrangement: the bezel is black and
    /// barely distinguishable from the display it holds, and the whole of the device is one
    /// machined highlight along the outside.
    ///
    /// So the body is drawn as dark as a body and no darker — flat black would take the edge away
    /// and leave the screen floating — with the light coming from the top, as it does on every
    /// other surface in the app.
    static let bodyTop = Color(red: 0.125, green: 0.125, blue: 0.138)
    static let bodyBottom = Color(red: 0.062, green: 0.062, blue: 0.072)
    static let rim = LinearGradient(
        colors: [.white.opacity(0.30), .white.opacity(0.08)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let rimWidth: CGFloat = 1

    /// The screen's height, given the box the whole device has to fit inside.
    ///
    /// Solved rather than measured in two passes, because the bezel is a fraction of the screen and
    /// the screen is the thing being solved for. Both limits — the box's height and its width —
    /// are linear in the screen's height once the bezel is written in terms of it, so each is a
    /// division and the tighter one wins. The floor keeps a zero-sized box, which is what the
    /// first layout pass offers, from being a division into something the geometry reader cannot
    /// draw.
    static func screenHeight(in box: CGSize) -> CGFloat {
        let byHeight = box.height / (1 + 2 * aspect * bezel)
        let byWidth = box.width / (aspect * (1 + 2 * bezel))
        return max(min(byHeight, byWidth), 1)
    }
}

/// The phone the tour holds up: one frame on every page, with only its screen changing.
///
/// The pages are about a single object, and a stage that is a bare glyph on one page and a card on
/// the next reads as five different screens rather than five views of one. So the frame is the
/// constant and the screen inside it is the variable — the shape is the app's shape from the first
/// page to the last, and each page's picture lands inside it.
///
/// The proportions are the marketing site's own mockup, down to the bezel and the corner: that
/// picture of the app and this one are the same claim about what the app looks like, and two
/// devices with different corner radii would be two claims.
private struct PhoneStage<Screen: View>: View {
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        GeometryReader { proxy in
            // Height is the constraint on a phone and width almost never is — but a short, wide
            // window is exactly where a height-only sum runs off the edge, so both are asked.
            let screenHeight = PhoneStageMetrics.screenHeight(in: proxy.size)
            let screenWidth = screenHeight * PhoneStageMetrics.aspect
            let bezel = screenWidth * PhoneStageMetrics.bezel
            let bodyWidth = screenWidth + bezel * 2
            let bodyHeight = screenHeight + bezel * 2
            let body = RoundedRectangle(
                cornerRadius: bodyWidth * PhoneStageMetrics.bodyCorner,
                style: .continuous
            )

            body
                .fill(
                    LinearGradient(
                        colors: [PhoneStageMetrics.bodyTop, PhoneStageMetrics.bodyBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    screen()
                        .frame(width: screenWidth, height: screenHeight)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: screenWidth * PhoneStageMetrics.screenCorner,
                                style: .continuous
                            )
                        )
                        // The island is part of the phone rather than part of the picture, so it is
                        // drawn here rather than expected in every screenshot. A screenshot of this
                        // app already has one — its own is black on a black backdrop — and the two
                        // land in the same place on the same device.
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.black)
                                .frame(width: screenWidth * 0.30, height: screenHeight * 0.038)
                                .padding(.top, screenHeight * 0.019)
                        }
                }
                .frame(width: bodyWidth, height: bodyHeight)
                // The machined edge, drawn inside the body rather than around it so that the
                // highlight is the last thing on the device and not a ring floating off it. One
                // point, following the same light as the body it sits on.
                .overlay {
                    body.strokeBorder(PhoneStageMetrics.rim, lineWidth: PhoneStageMetrics.rimWidth)
                }
                .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Plan choice

/// One plan on the last page: what it is called, what it costs, and one line about what it is for.
///
/// The row's subject is a tier rather than a product, so it is drawn whether or not the store has
/// answered and only the price waits on the answer — a list that appears in pieces as the products
/// arrive is a list that looks like it is still loading after it has finished.
/// One rung of the ladder on the last page, the free one included.
///
/// Takes the four strings rather than a ``StoreManager/Tier``, because the free plan has no tier:
/// it is the floor the other three are measured from and it is not for sale, so it has no product,
/// no price and no badge. A row that took a tier and special-cased free inside itself would put
/// that branch in the one place a reader checks when asking what the free plan includes.
private struct PlanChoice: View {
    let name: String
    /// What the rung is, in one line, on the axis the ladder is built on.
    let line: String
    /// `nil` for the free row, which has no price rather than a price of zero.
    let price: String?
    let recommended: Bool
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)

                        if recommended {
                            Text("BEST VALUE")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(ColorPalette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                        }
                    }

                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                // Left out entirely on the free row rather than printed as a zero: the rows to the
                // right are prices, and "Free" beside them is the absence of one. Every checkmark
                // still lands on the same edge, because the spacer above is what pushes them there.
                //
                // Three dots rather than a dash for a price the store has not answered with, for
                // the reason the paywall's copy of this line gives: a dash sitting where a price
                // goes reads as a minus sign.
                if let price {
                    Text(price)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? ColorPalette.accent : Color.white.opacity(0.22))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(selected ? 0.10 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ColorPalette.accent, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.985))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#Preview {
    OnboardingView(onFinish: {})
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
