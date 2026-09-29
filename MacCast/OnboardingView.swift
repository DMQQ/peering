import MacCastKit
import StoreKit
import SwiftUI
import UIKit

/// Six pages, swiped, in the order the app asks things of you.
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

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(StoreManager.self) var store

    @State var index = 0
    /// How much room the pages leave above their words, which is how tall the device is drawn.
    ///
    /// Reported by the pages themselves rather than worked out here, because it is whatever is left
    /// over and only a page knows that. All five report the same number by construction — the title
    /// is one line on every page and the words are held to ``tallestWords`` on every page — so five
    /// views writing to one value is one answer rather than a race. When it was not true the race
    /// was the least of it: the device simply came out a different size on the fourth page.
    @State var stageHeight: CGFloat = 0
    /// The tallest title-and-body block on any page, which is what every page's words are held to.
    ///
    /// Measured rather than written down — see ``bodyHeight`` for what the written-down version
    /// cost — and measured all at once rather than page by page, for the reason ``wordsRuler``
    /// gives. The largest ever seen rather than the last one seen, because it is written from more
    /// than one place and a plain assignment would be decided by whichever wrote last.
    @State var tallestWords: CGFloat = 0
    /// Whether the current page's contents have arrived, or are on their way in.
    ///
    /// One flag for the whole tour rather than one per page, and it is only ever read by the page
    /// that is on screen — see ``pageView(_:at:)``. Off-screen pages answer `true` regardless, so
    /// that the page being swiped away never empties itself in front of the user on its way out.
    @State var contentVisible = false
    /// The plan the last page is pointed at, or `nil` for the free one.
    ///
    /// **Opens on the cheapest rung that costs anything, which is neither of the two defaults this
    /// page has had.** It opened on the dearest first, so a five-page introduction ended by asking
    /// for a year of Pro, and that is what made the page read as a pitch rather than a choice. It
    /// opened on free next, which fixed the pitch and left the free plan as the only control on the
    /// page shaped like the way forward. Free is a row of its own one tap below and the Skip in the
    /// corner is the other way past it, so the biggest button here is the one that buys something.
    @State var chosen: StoreManager.Tier? = .relay

    /// How often this page offers to bill. Opens on monthly so the lower number is the first one
    /// read; the yearly is one tap away and the switch shows what it saves.
    @State var period: BillingPeriod = .monthly

    /// Whether the first page's download address has just been copied, which is what turns the
    /// clipboard into a tick for a moment. See ``copyAddress``.
    @State var addressCopied = false

    /// What Restore Purchases came to when the App Store found no entitlement or returned an
    /// error. Kept on this screen because a restore with no result must not look like an ignored
    /// tap; cleared before the next attempt and after one succeeds.
    @State var restoreNote: String?

    /// What the free row says, built from the number the relay actually meters.
    ///
    /// Read off ``RelayPlan`` for the reason every other allowance claim in the app is: "half an
    /// hour" typed onto a screen beside a server configured for one hour is the drift that
    /// turns a promise into a support email.
    static var freeLine: String {
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
    static let bodyHeight: CGFloat = 124

    static let pages: [Page] = [
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppMac"),
            title: "Install it once",
            // **First, because everything after it is impossible without it.** The page that
            // follows says to pick your Mac out of Nearby, which presumes a Mac that is running
            // this. The tour used to open by assuming that, and a first launch with only one of
            // the two apps installed had nothing to tell the user about the one they were missing.
            //
            // The body is two facts and no encouragement: which half is missing, and that
            // installing it is the whole of the setup. It used to be chatty about both — "open it
            // once, and the Mac is ready", "there is nothing to configure on the Mac", a trailing
            // clause pointing at the next page — which reassures a reader who has not yet been
            // given anything to doubt, and buries the one line that carries the instruction.
            //
            // The address is not in the prose either. It is a row under it, sized so that it is
            // the obvious thing on the page to press — see ``downloadLink``.
            body: """
                Put Peering on the Mac you want to reach and open it. That is the whole setup: \
                no account, router changes, or settings to configure.
                """,
            device: .mac(companion: "AppConnect")
        ),
        Page(
            content: .feature(icon: "wifi", screenshot: "AppConnect"),
            title: "Pair once. Stay connected.",
            body: """
                Choose your Mac, compare the six-digit code, and Peering remembers it. Next time, \
                reconnect nearby or from another network without pairing again.
                """
        ),
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppSources"),
            title: "See exactly what you need",
            body: """
                Bring over a whole display, one app, a single window, or any of your Spaces. Jump \
                between them whenever you like without ending the session.
                """
        ),
        Page(
            content: .feature(icon: "hand.point.up.left", screenshot: "AppControls"),
            title: "Your Mac, under your fingers",
            body: """
                Tap, type, scroll, zoom, use shortcuts, or steer the pointer with the joystick. \
                Switch to Observe whenever you only want to look.
                """
        ),
        Page(
            content: .feature(icon: "arrow.triangle.2.circlepath", screenshot: "AppPictureInPicture"),
            title: "Your session follows you",
            body: """
                Leave the app or lock your phone without losing the connection. Picture in Picture \
                keeps your Mac in view, while Live Activities keep the session close at hand.
                """
        ),
        Page(
            content: .feature(icon: "square.grid.2x2", screenshot: "AppMosaic"),
            title: "See everything at once",
            body: """
                Lay out windows, apps and displays side by side and watch them all live. Tap any \
                tile to take control, and come back to the arrangement when you are done.
                """
        ),
        // **The one claim the landing moved here and the tour did not already make.**
        //
        // Four claims left the landing page for this tour. Three of them — "come back from
        // anywhere", "control it like it is in front of you", "it stays with you" — are pages
        // below in the same words and were not duplicated; this one was nowhere else in the
        // product, so it is a page now rather than something the move would have deleted.
        //
        // Drawn rather than photographed: it is about a moment when nobody is looking at the
        // phone, so there is no screen of this app to capture for it, and the notification is the
        // whole of what the reader has to see.
        Page(
            content: .notification,
            title: "Told when a shell is waiting",
            body: """
                A build that finishes, a prompt for a password, a command that wants an answer: \
                the Mac tells you, on the Lock Screen and with the app closed.
                """
        ),
        Page(
            content: .plans,
            title: "Start free. Go farther when you need.",
            // One sentence, and the rows do the rest.
            //
            // **It used to be two paragraphs explaining the ladder**, over three rows that also
            // explained the ladder, in different words. The page was saying everything twice and
            // still leaving the reader to work out that the rows were steps rather than three
            // separate offers. What is left here is the one thing no row can say, which is that
            // the free plan is a real plan and not a trial.
            body: """
                Use Peering on your own network for free, for as long as you like. Upgrade when \
                you want more relay time or the tools built for working away from your Mac.
                """
        )
    ]

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularWidthBody
            } else {
                compactWidthBody
            }
        }
        .onAppear(perform: revealContent)
    }

    /// The phone layout is intentionally kept as the original implementation. A narrow iPad
    /// window therefore behaves like an iPhone instead of trying to squeeze a two-column layout
    /// into Split View.
    var compactWidthBody: some View {
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
            if !showsPlans {
                SkipButton(action: skip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    /// A bounded, two-column tour for full-width iPad and generous multitasking windows.
    ///
    /// The stage and copy each get a real column rather than letting the phone grow to consume
    /// every point an iPad offers. The pager still owns the entire surface, so swiping, page
    /// animation, the plan choice, and the fixed actions work exactly as they do on iPhone.
    var regularWidthBody: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { offset, page in
                        regularWidthPage(page, at: offset).tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay { regularWidthStage }

                indicator

                actions
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: 1180)

            if !showsPlans {
                SkipButton(action: skip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    @ViewBuilder
    func regularWidthPage(_ page: Page, at offset: Int) -> some View {
        let here = offset == index
        let shown = here ? contentVisible : true

        if case .plans = page.content {
            regularWidthPlansPage(page, shown: shown, lit: here)
        } else {
            regularWidthDevicePage(page, shown: shown, lit: here)
        }
    }

    /// The right column is reserved for the shared stage drawn above the pager. Keeping the stage
    /// shared preserves the continuous phone movement between pages while the words swipe.
    ///
    /// Text leads on the left, in reading order, with the device it describes beside it rather
    /// than in front of it — see ``regularWidthStage``, which mirrors this column.
    func regularWidthDevicePage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 22) {
                heading(page.title, lit: lit)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 14)
                    .animation(motion(delay: 0.09), value: shown)

                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 18)
                    .animation(motion(delay: 0.16), value: shown)

                if case .mac = page.device {
                    downloadLink
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 20)
                        .animation(motion(delay: 0.24), value: shown)
                }
            }
            .frame(maxWidth: 430, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }

    /// Plans stay a readable column rather than expanding each choice across the iPad. The list
    /// keeps its own scrolling, which also makes this fit short landscape and Stage Manager sizes.
    func regularWidthPlansPage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(page.title, lit: lit)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .animation(motion(delay: 0.09), value: shown)

            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)
                .animation(motion(delay: 0.16), value: shown)

            plans
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            legalLinks
        }
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .padding(.bottom, 8)
    }

    /// The shared iPad stage is capped in both dimensions. This is the key difference from the
    /// compact layout: extra canvas becomes breathing room, not a billboard-sized phone.
    var regularWidthStage: some View {
        GeometryReader { proxy in
            if !isLast {
                let columnWidth = max((proxy.size.width - 152) / 2, 1)
                let box = CGSize(
                    width: min(columnWidth, 430),
                    height: min(max(proxy.size.height - 72, 1), 520)
                )
                let laid = stageLayout(in: box)

                ZStack {
                    if case .mac = Self.pages[index].device {
                        MacDrawing(displayHeight: laid.macDisplay ?? 1) { deviceScreen }
                            .offset(laid.macOffset)
                            .transition(.opacity)

                        // The companion phone still shows the iPhone app on the Mac page: that page
                        // is about installing the Mac host, and the phone beside it is the device
                        // the reader is holding, not a second kind of iPad stage.
                        PhoneStage { phoneScreen }
                            .scaleEffect(laid.phoneScale, anchor: .center)
                            .offset(laid.phoneOffset)
                            .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    } else {
                        TabletStage { tabletScreen }
                            .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    }
                }
                .frame(width: box.width, height: box.height)
                // The right column, mirroring ``regularWidthDevicePage``: the words read first on
                // the left, and the device they describe sits beside them rather than in front.
                .position(x: proxy.size.width - 48 - columnWidth / 2, y: proxy.size.height / 2)
                .animation(Motion.settle, value: index)
            }
        }
        .allowsHitTesting(false)
    }

    /// One page, laid out the way its own content wants.
    ///
    /// **Two layouts, and the split is the point.** Five of the six pages are a picture with its
    /// words underneath, and those five share one set of rules so that the picture stays one
    /// picture: a box above the words for the device to be drawn in, and the words themselves held
    /// to the tallest page's so that the box comes out the same height on all five. The sixth page
    /// is a list, and none of that is true of a list.
    @ViewBuilder
    func pageView(_ page: Page, at offset: Int) -> some View {
        // The page being looked at animates; every other page is simply in place, so that the one
        // leaving during a button-led change keeps its contents while it slides out.
        let here = offset == index
        let shown = here ? contentVisible : true

        if case .plans = page.content {
            plansPage(page, shown: shown, lit: here)
        } else {
            devicePage(page, shown: shown, lit: here)
        }
    }

    /// The last page: the heading, and the plans under it.
    ///
    /// **Laid out from the top, and that is the whole of what changed.** It used to be a page like
    /// the others, reserving a device's box above its words and holding those words to the tallest
    /// page's height, and then filling the box with plan rows instead of a device. Both halves of
    /// that were wrong on a page with no picture on it. The box belongs to the device and this page
    /// has no device to size, and the held height is ``tallestWords``, which the five pages that
    /// *do* have bodies decide between them: a page with no body of its own still reserved one, its
    /// height, and left about a hundred and fifty points of nothing between the heading and the
    /// button.
    ///
    /// Which is why deleting the body bought the list nothing. The height being reserved was never
    /// the body's, so the hole it left was the hole that was always there. The heading is at the
    /// top now, the switch is under it, and the list takes everything that is left: the room the
    /// heading was holding open is the room the list scrolls in.
    func plansPage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(page.title, lit: lit)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .animation(motion(delay: 0.09), value: shown)

            plans
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            legalLinks
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        // The heading is the first thing on this page rather than the middle of it, which puts it
        // on the same line as `Skip` for the first time in the tour. This is what stops the two
        // reading as one row on a narrow phone.
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// The two links a subscription screen is expected to carry, styled as the paywall styles its
    /// own so that the same two links do not look like two different things one screen apart.
    ///
    /// **Nothing is bought on this page and the links are here anyway.** The rule is about screens
    /// where a subscription is sold, and this one only chooses between four plans: the button under
    /// it says "Start using Peering". But it shows four prices and a monthly/yearly switch, which
    /// is the whole of what makes a screen look like one where money is about to change hands, and
    /// "strictly not required" is a bad bet when being wrong costs a rejection and being right
    /// costs a row of caption text.
    var legalLinks: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                // App Review looks for restore on any screen that shows subscription prices.
                Button(store.isPurchasing ? "Restoring…" : "Restore purchases") {
                    restoreNote = nil
                    Task {
                        let restored = await store.restore()
                        restoreNote = PurchaseRestoreFeedback.message(
                            didRestore: restored,
                            error: store.purchaseError
                        )
                    }
                }
                .disabled(store.isPurchasing)
                Link("Privacy Policy", destination: Legal.privacy)
                Link("Terms of Use", destination: Legal.terms)
            }

            if let note = restoreNote {
                Text(note)
                    .foregroundStyle(store.purchaseError == nil ? .secondary : ColorPalette.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        // Centred, and it took a while to be. The page is laid out from its leading edge because
        // its heading and its rows are, and the two links came along with them: a rule about the
        // body of a page is not a rule about its footer, and the two one-line links a subscription
        // screen carries under everything else are the one thing here that is not a sentence to be
        // read left to right. They belong under the middle of the page they sign off.
        .frame(maxWidth: .infinity)
    }

    /// Every other page: the box the device is drawn in, and the words under it.
    func devicePage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
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
                heading(page.title, lit: lit)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 14)
                    .animation(motion(delay: 0.09), value: shown)

                if page.content.wordsAreHeld {
                    Text(page.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 18)
                        .animation(motion(delay: 0.16), value: shown)
                }

                // Last of the three beats, because it is the only thing on the page to do rather
                // than to read — and the one page that has one is the page whose subject is not
                // installed yet.
                if case .mac = page.device {
                    downloadLink
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 20)
                        .animation(motion(delay: 0.24), value: shown)
                }
            }
            .frame(minHeight: max(Self.bodyHeight, tallestWords), alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    /// A page's title, which is a *name* and is set as one: the display face, negatively tracked,
    /// with the light that crosses the wordmark travelling over it.
    ///
    /// **The light is the one from the landing, and not a second one like it.** The first screen
    /// shows `Peering` under a sweep and the tour that follows it says what the app does in the
    /// same face at the same weight; a heading that sat still would make the sign the only lit thing
    /// in the app, which is the opposite of what a sign is. It is the same modifier, so the two
    /// cannot drift into two effects.
    ///
    /// It costs the page 22% of its brightness (see ``Sheen/paint`` for why that is the effect's
    /// price rather than a taste), and it is only drawn on the page being looked at. The `TabView`
    /// builds this page's neighbours, and a sweep running behind two pages nobody can see is three
    /// timelines for one effect.
    func heading(_ title: String, lit: Bool) -> some View {
        Text(title)
            .font(DisplayFont.display(.largeTitle))
            .tracking(-1)
            .sheen(active: lit && !reduceMotion)
    }

    func motion(delay: Double) -> Animation? {
        reduceMotion ? nil : Motion.arrive.delay(delay)
    }

    /// Five capsules, and the one you are on is the long one.
    ///
    /// The page style's dots say how many pages there are and where you are, in the same shape
    /// twice: four identical circles, one of them filled. A capsule that grows says where you are
    /// in the *length* of the thing that moved, and it says it as a movement — pressing Next turns
    /// the pill back into a dot and stretches the next one out, which is the only motion on this
    /// screen that belongs to the change between pages rather than to a page.
    ///
    /// Sized against the width class rather than left at the phone's numbers everywhere: those
    /// were chosen next to a phone's `.largeTitle` heading, and beside the same heading grown into
    /// an iPad's regular-width column the row read as a phone detail left behind at its own scale.
    var indicator: some View {
        let isRegular = horizontalSizeClass == .regular
        let dotSize: CGFloat = isRegular ? 8 : 6
        let activeWidth: CGFloat = isRegular ? 32 : 24

        return HStack(spacing: isRegular ? 8 : 6) {
            ForEach(0..<Self.pages.count, id: \.self) { page in
                Capsule()
                    .fill(page == index ? ColorPalette.ink : Color.white.opacity(0.22))
                    .frame(width: page == index ? activeWidth : dotSize, height: dotSize)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: index)
        .padding(.top, isRegular ? 8 : 4)
        .padding(.bottom, isRegular ? 26 : 20)
        .accessibilityHidden(true)
    }

    /// Brings the current page's contents back in.
    ///
    /// The contents are taken away for one frame before being animated in, and the frame matters:
    /// setting the flag to `false` and `true` in the same update animates from `true` to `true`,
    /// which is no animation at all and is how this kind of stagger usually ends up doing nothing.
    func revealContent() {
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
    var actions: some View {
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

    var isLast: Bool { index == Self.pages.count - 1 }

    /// Skips the tour, not the plans: someone without a plan lands on the plans page, which has
    /// its own way on for free.
    func skip() {
        guard !store.isPro else { return onFinish() }
        withAnimation(Motion.settle) { index = Self.pages.count - 1 }
    }

    /// Whether the page on screen is offering a plan, which is the last one and only while there
    /// is something left to buy.
    var showsPlans: Bool { isLast && !store.isPro }

    /// The button's label, which is the price on the page that has one.
    ///
    /// The price belongs on the button rather than only on the rows above it: those say what each
    /// tier is, and this is the moment the money is decided, so it is the last place the number
    /// can be read before it is spent.
    var primaryTitle: String {
        guard showsPlans else { return isLast ? "Get started" : "Next" }

        // Free chosen, or a rung the store has not priced yet. The button says what it does rather
        // than naming an amount, because in both cases it is the way into the app and not a
        // purchase, and the two are one question, so a page still waiting on the store cannot
        // label itself with a price and then not charge it.
        guard let chosen,
              let price = store.compactPriceLabel(for: chosen, period: period)
        else { return "Start using Peering" }

        if store.isPurchasing { return "Contacting the App Store…" }
        return "Continue with \(chosen.name) · \(price)"
    }

    func primaryAction() {
        // No tier chosen is the free plan, and the free plan is not a purchase: it is the button
        // that finishes the introduction. A rung with no product behind it is the same case for
        // the same reason its label is, which is that the button said as much before it was
        // pressed.
        guard showsPlans, let chosen,
              let product = store.product(for: chosen, period: period)
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
    func advance() {
        guard !isLast else {
            onFinish()
            return
        }
        revealContent()
        withAnimation(Motion.arrive) { index += 1 }
    }

    var light: some View {
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
    struct Page {
        let content: Content
        let title: String
        let body: String

        /// Which machine the page's stage draws.
        ///
        /// **One page is about something the user does not have yet**, and drawing the Mac app
        /// inside a phone would be the one picture in this file that lies about what the app looks
        /// like. Defaulted rather than required: the other five all draw the phone, and saying so
        /// five times is five chances to say it differently.
        ///
        /// It carries more than the name of a frame on that one page. The Mac is only half of what
        /// the first page is about — the other half is the phone the reader is holding — so the
        /// case carries the screenshot that phone shows, and the page that draws a Mac is also the
        /// page that owes the download row. Both follow from which page this is, and neither can
        /// be said in a second place and disagree with it.
        var device: Device = .phone

        enum Device {
            case phone
            /// The Mac, with the phone standing in front of it. `companion` is what that phone's
            /// screen shows: the app's own first screen, which is the one the page is asking the
            /// reader to bring a Mac to.
            case mac(companion: String)
        }

        /// What the page puts in the stage at the top.
        ///
        /// A type rather than a view so that the kinds of page are told apart by the same list, in
        /// the same order, with the same page dots, rather than by an index comparison somewhere in
        /// the body.
        enum Content {
            /// A page about something the app does. `screenshot` is the phone capture; `tabletScreenshot`
            /// is the iPad capture shown on regular-width layouts. Either is `nil` until taken, in which
            /// case the frame shows its glyph.
            case feature(icon: String, screenshot: String? = nil, tabletScreenshot: String? = nil)
            /// The page whose picture is drawn rather than captured: this app's own notification,
            /// which ``NotificationBanner`` draws.
            case notification
            /// The last page: what there is to buy.
            case plans

            /// Whether this page's words go in the block every other page's do, the one held to the
            /// tallest of them. The plans page is the one that does not: it lays itself out from the
            /// top and draws its own body.
            var wordsAreHeld: Bool {
                switch self {
                case .feature, .notification: return true
                case .plans: return false
                }
            }
        }
    }
}
