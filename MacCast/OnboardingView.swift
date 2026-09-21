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

    /// How often this page offers to bill. Opens on monthly so the lower number is the first one
    /// read; the yearly is one tap away and the switch shows what it saves.
    @State private var period: BillingPeriod = .monthly

    /// Whether the first page's download address has just been copied, which is what turns the
    /// clipboard into a tick for a moment. See ``copyAddress``.
    @State private var addressCopied = false

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

    /// One page, laid out the way its own content wants.
    ///
    /// **Two layouts, and the split is the point.** Five of the six pages are a picture with its
    /// words underneath, and those five share one set of rules so that the picture stays one
    /// picture: a box above the words for the device to be drawn in, and the words themselves held
    /// to the tallest page's so that the box comes out the same height on all five. The sixth page
    /// is a list, and none of that is true of a list.
    @ViewBuilder
    private func pageView(_ page: Page, at offset: Int) -> some View {
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
    private func plansPage(_ page: Page, shown: Bool, lit: Bool) -> some View {
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
    private var legalLinks: some View {
        HStack(spacing: 18) {
            Link("Privacy Policy", destination: Legal.privacy)
            Link("Terms of Use", destination: Legal.terms)
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
    private func devicePage(_ page: Page, shown: Bool, lit: Bool) -> some View {
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

                if case .feature = page.content {
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

    // MARK: - The stage

    /// The five pages with devices on them, their words laid out at once and thrown away, so that
    /// the tallest of them can size every one of their words blocks.
    ///
    /// **The plans page is not one of them.** It is the one page with no device to size, so it is
    /// the one page whose words are not held to anything; measuring it here would let a long
    /// heading it does not have to answer for go into the height the other five are held to.
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
    ///
    /// **Everything a page draws goes in here too, and the download row is the proof.** A page whose
    /// words are taller than this ruler believes them to be is a page that pushes its own contents
    /// past the block sized to hold them, which is the same fault ``bodyHeight`` describes from the
    /// other side: the device is sized from the room the words leave, so the ruler being short is
    /// the device being wrong on every page.
    /// The pages whose words are held to the tallest of them, which is every page but the plans.
    ///
    /// Asked as a question about the content rather than written down as a range, so that adding a
    /// page without a device to it later cannot quietly inherit a rule that has nothing to say
    /// about it.
    private static var measuredPages: [Page] {
        Self.pages.filter { page in
            if case .plans = page.content { return false }
            return true
        }
    }

    private var wordsRuler: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.measuredPages.enumerated()), id: \.offset) { _, page in
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.title)
                        .font(DisplayFont.display(.largeTitle))
                        .tracking(-1)

                    if case .feature = page.content {
                        Text(page.body)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if case .mac = page.device {
                        downloadLink
                    }
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
        // Drawn for its height and nothing else, and since the download row it now measures is a
        // link, it has to be told: a hidden view is still a view that takes taps, and five of these
        // stacked behind the pages would be five invisible targets on the screen it is measuring.
        .allowsHitTesting(false)
    }

    /// The way off the first page and onto the Mac, as a row under its words.
    ///
    /// **A row rather than an address inside a sentence.** The first page is the only place in the
    /// app that tells somebody where the other half of the product comes from, and it used to say
    /// it in the middle of a paragraph: nothing to press, nothing to copy, and an address set in the
    /// same grey as the prose around it. The address is the whole of the instruction, so it is what
    /// this row is and the largest type on the page after the title.
    ///
    /// The row is the target rather than the words in it, and it is drawn on ``rowSurface()``, which
    /// is the one filled surface in the app and the one shape that says a thing can be pressed
    /// without a button having to. The arrow points out of the app, which is what the link does: the
    /// Mac app is a download rather than an App Store install, so the tap leaves for a browser.
    ///
    /// Not a button of its own beside the primary one at the bottom: the tour's way forward is one
    /// control in one place, and this is a fact about the page rather than the way to leave it.
    ///
    /// **Two controls in one row, and the trailing one is a clipboard.** The address is as often
    /// something to say out loud or paste into a message as it is something to open, and this screen
    /// is the only place in the app that knows it: an address on a phone with no way to copy it
    /// means reading it off the display and typing it into something else, which is the one thing
    /// this row exists to avoid. So the row opens and the button copies, as two labelled targets
    /// rather than one target that guesses.
    ///
    /// The whole path is written out rather than the host alone, because the host alone is not the
    /// address anybody types: `getpeering.app` alone lands on a page one tap further from the file,
    /// and a copy button that copies something other than what is written above it is worse than no
    /// copy button at all.
    private var downloadLink: some View {
        HStack(spacing: 4) {
            Link(destination: PeeringSite.download) {
                HStack(spacing: 12) {
                    Text("getpeering.app/download")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        // One line at every text size, because the address is the one string here
                        // that cannot be wrapped: broken across two lines it stops looking like
                        // something to type. It shrinks instead, which it has room to do.
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.98))
            .accessibilityLabel("Download Peering for Mac from getpeering.app")

            copyAddress
        }
        .padding(.trailing, 10)
        .rowSurface()
    }

    /// The clipboard half of the row above.
    ///
    /// It answers in place rather than off to the side, as the diagnostics card's copy button does:
    /// the tick appears where the tap landed, which is the only place a user who has just tapped
    /// will look, and it goes back on its own so that the row is not left claiming to have copied
    /// something an hour later.
    private var copyAddress: some View {
        Button {
            UIPasteboard.general.string = "getpeering.app/download"
            addressCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                addressCopied = false
            }
        } label: {
            Image(systemName: addressCopied ? "checkmark" : "doc.on.doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(addressCopied ? ColorPalette.ink : .secondary)
                // A 44-point target around a 17-point glyph. The row it sits in is a comfortable
                // one to press anywhere on, and this is the control in it that must not be.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(addressCopied ? "Address copied" : "Copy the download address")
    }

    /// The room above the words, holding the machines for the whole tour.
    ///
    /// This used to be a page's own business — five pages, five frames — and five frames is what it
    /// looked like: pressing Next slid one phone off the left of the screen while another slid in
    /// from the right, shrinking as it came, so the object the tour is about left and returned on
    /// every page. A device that does that is not one device. Drawn here instead, once, and what
    /// moves between pages is what it is holding.
    ///
    /// **One stage, and not one shape.** The first page is about there being two apps, so what it
    /// holds is the pair — the Mac with the phone in front of it — and the other four hold the phone
    /// alone, which is why the pair is solved from the same box as the phone and not given a stage
    /// of its own. The box has to fit the tallest of them, and it does, because they are sized from
    /// it rather than against each other.
    ///
    /// The last page has nothing to hold. The device is taken away rather than kept and refilled,
    /// and the three plans are that page's own content rather than something drawn in here: they
    /// are a list to press, and the same rows inside a phone would read as a picture of a screen
    /// rather than as something to touch. So on that page the stage draws nothing at all and the
    /// page lays itself out from the top.
    ///
    /// **Two machines and one of each, which is what lets the phone grow.** The phone is drawn once
    /// for the whole tour (see ``StageLayout`` for what that replaced), and the Mac is drawn beside
    /// it on the one page that has one. Between the first page and the second the Mac fades and the
    /// phone, which has been standing in front of it at ``MacAndPhoneMetrics/phoneScreen`` of the
    /// display, travels to the middle of the stage and grows to fill it: the same drawing at a new
    /// scale, rather than one phone leaving and a larger one arriving under cover of a cross-fade.
    private var stage: some View {
        GeometryReader { proxy in
            let laid = stageLayout(in: proxy.size)

            ZStack {
                // The Mac, on the page whose whole argument it is: the app is a second download,
                // and the phone is holding the reason to go and get it.
                if case .mac = Self.pages[index].device {
                    MacDrawing(displayHeight: laid.macDisplay ?? 1) { deviceScreen }
                        .offset(laid.macOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // **The one device the tour is about**, and it is given a shorter departure than
                // everything else on this screen. The last page is a list to read rather than a
                // picture to look at, and a phone that spends the whole page turn fading out of the
                // corner of an eye is a phone that is still there while the reader has started
                // reading. It goes in a seventh of a second, which reads as the device having been
                // taken away rather than as one that is leaving.
                if !isLast {
                    PhoneStage { phoneScreen }
                        .scaleEffect(laid.phoneScale, anchor: .center)
                        .offset(laid.phoneOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeOut(duration: 0.14)))
                }
            }
            // The stage fills its box rather than sizing to what is in it, because a `GeometryReader`
            // places its content at the top leading corner: without this the machines would be
            // centred in a box the size of themselves and then pinned to the corner of the real one.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: stageHeight)
        .padding(.horizontal, 22)
        // One animation for the whole stage, because a page turn is one event: the Mac leaving, the
        // phone growing and the picture inside it dissolving all start on the same frame or the
        // movement reads as three things happening at once. `settle` rather than a curve, because
        // the phone is an object with weight being moved rather than a fade, and it is the only
        // thing on this screen that a page turn makes *travel*, so its arrival is the page turn.
        .animation(Motion.settle, value: index)
    }

    /// Where the stage's two machines stand, in the box it has been given.
    ///
    /// **Solved rather than laid out, and that is the whole of what makes the phone grow.** The
    /// phone used to be laid out twice: once as a child of the pair's `HStack` on the first page, at
    /// ``MacAndPhoneMetrics/phoneScreen`` of the Mac's display, and once alone and centred on the
    /// other four. Two layouts is two objects, and the cross-fade between them was covering for the
    /// fact that there was nothing continuous to watch: pressing Next slid one phone away and a
    /// second, larger one in, and the tour's subject left the screen and came back on every page it
    /// moved to. One phone, drawn at the size it is when it is alone and moved to wherever the page
    /// wants it, is a phone that grows.
    ///
    /// The numbers are the pair's own, read in the units ``MacAndPhoneMetrics`` already writes them
    /// in: fractions of the Mac's display width. ``MacAndPhoneMetrics/displayHeight(in:)`` returns
    /// the display height that makes the pair fit the box, the display's width follows from its
    /// aspect, and the rest is the `HStack`'s arithmetic written out: two children bottom-aligned
    /// on one floor, the phone standing over the Mac's right-hand edge by
    /// ``MacAndPhoneMetrics/overlap`` of the display, the Mac lifted off that floor by
    /// ``MacAndPhoneMetrics/macLift`` because of the two the near one is the low one.
    ///
    /// The box's middle is the origin of both offsets, so the standalone phone's offset is zero:
    /// that is what "centred" means and it is why only the pair needs arithmetic.
    private func stageLayout(in box: CGSize) -> StageLayout {
        // The phone on its own, which is the size the drawing is built at. It has to be: the pair's
        // phone is the *smaller* of the two, so building at the pair's size and scaling up would
        // leave every page after the first rendering a photograph of a phone at 120% of what
        // somebody drew.
        let alone = PhoneStageMetrics.screenHeight(in: box) * PhoneStageMetrics.aspect

        var laid = StageLayout()
        guard case .mac = Self.pages[index].device else { return laid }

        let parts = MacAndPhoneMetrics.parts
        let displayHeight = MacAndPhoneMetrics.displayHeight(in: box)
        let display = displayHeight * MacStageMetrics.aspect

        // The pair, in points.
        let macWidth = display * parts.macWidth
        let macHeight = display * parts.macHeight
        let macColumn = display * parts.macColumn
        let pairWidth = display * parts.width
        let pairHeight = display * parts.height

        // The Mac is the pair's left-hand child, standing on the floor the pair's height puts under
        // it. Its drawing sits at the top of the column it stands in, which is that column less the
        // lift the pair gives it, so what is measured from the box's middle has to come back up by
        // the difference between the column and the drawing.
        laid.macDisplay = displayHeight
        laid.macOffset = CGSize(
            width: -pairWidth / 2 + macWidth / 2,
            height: pairHeight / 2 - macColumn + macHeight / 2
        )

        // And the phone is the right-hand one, bottom-aligned, drawn over the Mac's edge.
        laid.phoneScale = display * MacAndPhoneMetrics.phoneScreen / alone
        laid.phoneOffset = CGSize(
            width: pairWidth / 2 - display * parts.phoneWidth / 2,
            height: pairHeight / 2 - display * parts.phoneHeight / 2
        )
        return laid
    }

    /// Where the stage's machines stand on the page being shown, solved from the box it has.
    ///
    /// A value rather than two sets of views, because the phone is one of them: everything the tour
    /// draws for four of its six pages is a scale and an offset applied to a single drawing.
    private struct StageLayout {
        /// The Mac's display height, or `nil` on every page but the first. Read by ``MacDrawing``,
        /// which is only ever built when this is not `nil`. The fallback in the stage is there to
        /// keep the arithmetic total rather than to be used.
        var macDisplay: CGFloat?
        /// Where the Mac's drawing sits, measured from the middle of the box.
        var macOffset: CGSize = .zero

        /// The phone, against the size it is drawn at. One on the five pages it is alone.
        var phoneScale: CGFloat = 1
        var phoneOffset: CGSize = .zero
    }

    /// What is inside the frame, whichever machine the frame is.
    ///
    /// Keyed by the page so the picture inside the frame cross-dissolves as the words slide. One
    /// frame that swaps its contents reads as one device; one frame whose contents change instantly
    /// reads as a cut between two clips.
    private var deviceScreen: some View {
        screen(for: index)
            .id(index)
            .transition(.opacity)
    }

    /// What the phone is holding, which is not always what the page is about.
    ///
    /// The first page is about the Mac app, and the phone standing in front of it is holding *this*
    /// app's own first screen (see ``companionScreen(_:)``). Every other page puts the page's own
    /// picture in the phone, which is what ``deviceScreen`` is.
    ///
    /// The two are the same picture on the first page and the second, which is worth knowing before
    /// changing either: the pair's companion and the second page's screenshot are both `AppConnect`,
    /// so the picture inside the frame does not change as the phone grows out of the pair. The
    /// reader is watching one app's screen all the way from the small phone to the large one.
    @ViewBuilder
    private var phoneScreen: some View {
        if case .mac(let companion) = Self.pages[index].device {
            companionScreen(companion)
        } else {
            deviceScreen
        }
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
            picture(icon: icon, screenshot: screenshot)

        case .plans:
            // Never drawn — the last page takes the device away — but the switch has to answer.
            Color.black
        }
    }

    /// The second picture on the first page: what the phone in front of the Mac is showing.
    ///
    /// Not a page's picture, which is why it does not come through ``screen(for:)`` — it is the
    /// same app the reader is holding, on the screen that asks for a Mac, and it is there to make
    /// the page's pair read as two ends of one product rather than as a laptop and a phone. Its
    /// fallback glyph is a phone rather than the Mac's window, because what is missing in that
    /// case is a picture of *this* app.
    @ViewBuilder
    private func companionScreen(_ screenshot: String) -> some View {
        picture(icon: "iphone", screenshot: screenshot)
            // Keyed by its own name so it cross-dissolves like every other screen does when the
            // tour turns a page.
            .id(screenshot)
            .transition(.opacity)
    }

    /// A screenshot, or the glyph that stands in for one that has not been taken yet.
    ///
    /// Naming a screenshot before taking it is the ordinary order to work in — the page is written,
    /// then the picture is made — so this is a state the tour is expected to pass through rather
    /// than a mistake. The frame still draws, so the page has the same shape as its neighbours, and
    /// the glyph says which page is waiting for its picture.
    @ViewBuilder
    private func picture(icon: String, screenshot: String?) -> some View {
        if let screenshot, UIImage(named: screenshot) != nil {
            Image(screenshot)
                .resizable()
                .scaledToFill()
        } else {
            placeholder(icon)
        }
    }

    /// The glyph a frame shows while the page it belongs to has no screenshot to put in it: what
    /// ``picture(icon:screenshot:)`` falls back to.
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
        } else {
            VStack(spacing: 10) {
                BillingPeriodPicker(period: $period, saving: store.smallestYearlySaving)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        // Free first, because it is the floor the other three are measured from
                        // rather than a fourth thing on offer.
                        PlanChoice(
                            name: "Free",
                            line: Self.freeLine,
                            price: "No charge",
                            recommended: false,
                            selected: chosen == nil,
                            select: { chosen = nil }
                        )

                        ForEach(StoreManager.Tier.allCases) { tier in
                            PlanChoice(
                                name: tier.name,
                                line: tier.tagline,
                                price: store.priceLabel(for: tier, period: period) ?? "···",
                                recommended: tier.isRecommended,
                                selected: chosen == tier,
                                features: tier.features,
                                select: { chosen = tier }
                            )
                        }
                    }
                    .animation(Motion.tap, value: chosen)
                    .animation(Motion.tap, value: period)
                }
                // Three plans with their feature lists are taller than the room the page leaves
                // them, so the list is cut at both ends of the scroll. A hard cut through the
                // middle of a card reads as a card that has been sliced, which is the one thing a
                // list that is scrollable should never look like. The last few points fade into
                // the backdrop instead, and the same at the top, where the cards pass under the
                // switch.
                //
                // A mask rather than a gradient drawn over the ends: the page already sits on
                // ``ColorPalette/backdrop``, so fading the content out is fading it to the colour
                // that is already there, and nothing here has to know what that colour is.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.25), location: 0),
                            .init(color: .black, location: 0.025),
                            .init(color: .black, location: 0.95),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
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
    private func heading(_ title: String, lit: Bool) -> some View {
        Text(title)
            .font(DisplayFont.display(.largeTitle))
            .tracking(-1)
            .sheen(active: lit && !reduceMotion)
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

        guard let price = store.compactPriceLabel(for: chosen, period: period)
        else { return "Continue" }

        if store.isPurchasing { return "Contacting the App Store…" }
        return "Continue with \(chosen.name) · \(price)"
    }

    private func primaryAction() {
        // No tier chosen is the free plan, and the free plan is not a purchase: it is the button
        // that finishes the introduction.
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
    /// **Black, because that is what the front of an iPhone is.** The bezel around the display is
    /// the same black glass as the display, so face on the device is one black rectangle with a
    /// machined highlight around it, and the screen in it is a hole in that black rather than a
    /// picture in a frame. It used to be white at 18% fading to 5%, which over this near-black
    /// backdrop is not a device at all but a bright band, and a bright band is what the eye
    /// measures when it decides how thick a frame is, which is what was making this look like a
    /// mount. The two near-black greys it became were the right idea at half strength: a laptop lid
    /// has a bezel of its own colour, and a phone's does not.
    ///
    /// ``MacStageMetrics/lid`` has been black all along, so this is the two machines agreeing about
    /// what these devices look like rather than a detail the phone lost. Nothing goes with it
    /// either: the shape is described by ``rim``, which is the light along the outside edge and the
    /// same highlight the Mac has, and that was the only thing describing it in the first place.
    static let body = Color.black
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
/// **Sized at one, and moved by the stage.** This is the phone as it is when it is alone, and it is
/// the only size the drawing is ever built at: the first page wants it smaller, standing in front of
/// the Mac, and the stage scales this down to put it there (see ``OnboardingView/stageLayout(in:)``).
/// Scaling the drawing down to a size and holding it there is one phone; drawing it at the pair's
/// size and scaling it up to this one would be a phone rendered at 120% of itself for the rest of
/// the tour.
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

            PhoneDrawing(screenWidth: screenHeight * PhoneStageMetrics.aspect) { screen() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The phone's body, bezel, screen and island, at a width the caller has already solved for.
///
/// Split out of ``PhoneStage`` so that drawing a phone and deciding how big it is are two jobs: the
/// stage solves one size for a box, and this draws at whatever size it is handed. Everything inside
/// is the site's mockup, drawn from the screen's width and nothing else, which is also what makes
/// the drawing safe to scale, because every part of it is a fraction of that one number.
private struct PhoneDrawing<Screen: View>: View {
    /// The screen's own width. The bezel, the body and the corners are all fractions of it, so this
    /// is the one number the drawing needs.
    let screenWidth: CGFloat
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let screenHeight = screenWidth / PhoneStageMetrics.aspect
        let bezel = screenWidth * PhoneStageMetrics.bezel
        let bodyWidth = screenWidth + bezel * 2
        let bodyHeight = screenHeight + bezel * 2
        let body = RoundedRectangle(
            cornerRadius: bodyWidth * PhoneStageMetrics.bodyCorner,
            style: .continuous
        )

        body
            .fill(PhoneStageMetrics.body)
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
    }
}

/// The Mac's frame, from the site's `.mac` mockup, which is the same drawing.
///
/// **Fractions rather than points, for the reason ``PhoneStageMetrics`` argues at length**: the
/// site draws these machines at a fixed size and this file derives them from whatever the stage can
/// spare, so a fixed border in one place and a derived one in the other is two machines. Every
/// number below is the site's ratio, and changing one means changing `styles.css` with it.
private enum MacStageMetrics {
    /// The display's own proportions, 1512 by 982. A frame that did not match them would letterbox
    /// or crop the one picture it exists to hold, and the capture it holds is exactly this shape.
    static var aspect: CGFloat { 1512.0 / 982.0 }

    /// The lid's bezel, as a fraction of the display it surrounds.
    static let bezel: CGFloat = 0.017
    /// The lid's top corners, and its lower ones. The lower pair is much tighter, which is the
    /// shape rather than a detail: the lid is a panel, and only its top edge is a machined roll.
    static let lidCorner: CGFloat = 0.030
    static let lidLowerCorner: CGFloat = 0.009

    /// The base, as fractions of the lid it sits under and of its own height.
    static let baseHeight: CGFloat = 0.030
    /// Wider than the lid. This is the whole of why the two read as one machine rather than as a
    /// screen standing on a bar.
    static let baseOverhang: CGFloat = 1.055
    static let baseCorner: CGFloat = 0.36

    /// The camera housing, which every MacBook Pro since 2021 has.
    ///
    /// Part of the machine rather than part of the picture: a screenshot cannot contain it, because
    /// it is not something the display draws, it is something the display is missing. Drawn over
    /// whatever is in the screen, in the black of the housing.
    static let notchWidth: CGFloat = 0.092
    static let notchHeight: CGFloat = 0.026
    static let notchCorner: CGFloat = 0.013

    /// The scoop in the front edge, which is the one detail that says MacBook rather than laptop.
    static let scoopWidth: CGFloat = 0.15
    static let scoopHeight: CGFloat = 0.55

    /// The machines' own colours. The lid is black, because the lid of a MacBook is black glass and
    /// the bezel and the housing in it are the same black; that is the whole point of the notch,
    /// which is a cut in the display rather than a shape stuck onto it. The base is the site's two
    /// greys, and the rim is the phone's own, because it is the same machined edge.
    static let lid = Color.black
    static let baseTop = Color(red: 0.110, green: 0.110, blue: 0.122)
    static let baseBottom = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let scoop = Color(red: 0.024, green: 0.024, blue: 0.027)
    static let hinge = LinearGradient(
        colors: [.clear, .white.opacity(0.20), .clear],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// The pair's own numbers, which are the site's `.stage` rules written as fractions of the Mac's
/// display — the same unit `styles.css` uses, for the same reason.
///
/// **The first page is about there being two apps**, so its stage is the pair and not a machine: a
/// laptop alone on the page that says "install this on your Mac" leaves the reader holding the half
/// of the product nobody is talking about. The arrangement is the marketing site's hero, down to
/// the overlap and the lift: the same two screenshots in the same two frames, because it is the
/// same claim about the product and two compositions would be two claims.
///
/// The fraction the phone is drawn at is not the true one. An honest 14-inch MacBook beside an
/// honest iPhone draws the phone at about half the width it is given here, and a screenshot nobody
/// can read is not a screenshot. It is the fraction that keeps both legible.
private enum MacAndPhoneMetrics {
    /// The phone's screen, as a fraction of the Mac's display width.
    static let phoneScreen: CGFloat = 0.46

    /// How far the phone stands over the Mac's right-hand edge, as a fraction of the display width.
    /// This is the site's `-0.14`, and it is what makes the phone *in front of* the Mac rather than
    /// beside it.
    static let overlap: CGFloat = 0.14

    /// How much the Mac is lifted above the floor the phone stands on, as a fraction of the display
    /// width. The site's `margin-bottom` on the Mac, and the whole of why the pair reads as two
    /// objects on one surface rather than as one picture cropped twice.
    static let macLift: CGFloat = 0.035

    /// The pair's parts, named so that the solve for its size and the arithmetic that stands the
    /// phone in it cannot drift apart.
    ///
    /// This used to be an `HStack` with the Mac and the phone in it, and the parts were the
    /// expressions inside its two children. The phone cannot be a child of it any more: it has to
    /// be one drawing across the whole tour so that it can grow from the pair into the stage. So
    /// the `HStack` was written out as the arithmetic it always was, and these are the terms it
    /// comes to. Both readers are in ``OnboardingView/stageLayout(in:)`` now; the sum is here
    /// because the numbers are the pair's rather than the stage's.
    ///
    /// Every length is a multiple of the Mac's display width, which is the site's own unit.
    struct Parts {
        /// The Mac's widest part, which is its base.
        let macWidth: CGFloat
        /// The Mac's own height, and its height including the lift it stands on.
        let macHeight: CGFloat
        let macColumn: CGFloat
        /// The phone's body, over the screen it holds.
        let phoneWidth: CGFloat
        let phoneHeight: CGFloat
        /// What the two make together, which is what the box is fitted against.
        let width: CGFloat
        let height: CGFloat
    }

    static var parts: Parts {
        let mac = MacStageMetrics.self
        let phone = PhoneStageMetrics.self

        let lid = 1 + 2 * mac.bezel
        let phoneWidth = phoneScreen * (1 + 2 * phone.bezel)
        let phoneHeight = phoneScreen * (1 / phone.aspect + 2 * phone.bezel)
        // The bezel above and below the display, and the base under it. The lift is not part of the
        // machine and is not counted here: it is what the Mac stands on, not what it is.
        let macHeight = 1 / mac.aspect + 2 * mac.bezel + lid * mac.baseHeight

        return Parts(
            macWidth: lid * mac.baseOverhang,
            macHeight: macHeight,
            macColumn: macHeight + macLift,
            phoneWidth: phoneWidth,
            phoneHeight: phoneHeight,
            // The phone drawn *over* the Mac's edge, so the pair is narrower than its two parts by
            // the strip they share. This is the `HStack`'s negative spacing.
            width: lid * mac.baseOverhang + phoneWidth - overlap,
            // The taller of the two columns, because they stand on one floor. It is the phone: a
            // laptop is wide and a phone is nearly all screen.
            height: max(macHeight + macLift, phoneHeight)
        )
    }

    /// The display's height, given the box the pair has to fit inside.
    ///
    /// Solved rather than measured in two passes, for the reason
    /// ``PhoneStageMetrics/screenHeight(in:)`` gives, and by the same method: every dimension of
    /// both machines is linear in the display's height once every fraction is written in terms of
    /// it, so the width limit and the height limit are each one division and the tighter one wins.
    ///
    /// **Two limits that the Mac alone does not have.** The width now carries the phone across the
    /// Mac's right edge, and the height now has to clear the phone, which is the taller of the two
    /// — a phone standing on the same surface as a laptop, and a phone is nearly all screen.
    ///
    /// Everything here is written in units of the Mac's display *width*, which is the site's own
    /// unit: the display's height is the one term that has to be turned into it, and every other
    /// number is already a fraction of it. What the box then decides is the one scale both machines
    /// are drawn at, which is why the two limits are the pair's own width and height and nothing
    /// else.
    static func displayHeight(in box: CGSize) -> CGFloat {
        let parts = Self.parts

        // A display width is a display height times the aspect, so each limit is the box divided by
        // its own ratio: the aspect appears once, because both limits are measured in widths.
        let byHeight = box.height / (MacStageMetrics.aspect * parts.height)
        let byWidth = box.width / (MacStageMetrics.aspect * parts.width)
        return max(min(byHeight, byWidth), 1)
    }
}

/// The lid, the screen, the notch and the base, at a size the caller has already solved for.
///
/// **A second frame rather than a second screen for the first one.** The tour's pages are about
/// what the app does, and the one page that is about the Mac app has nothing to show until that
/// app has been installed: a phone frame with a Mac screenshot inside it would be the one drawing
/// in this file that says something untrue about the product. Its proportions come from the same
/// place ``PhoneDrawing``'s do, which is the site, so the two devices are one claim about what
/// these machines look like.
///
/// Drawn from a size rather than solving for one, for the reason ``PhoneDrawing`` is: the page that
/// holds it is solving one size for two machines (this one and the phone standing over it), so
/// neither may size itself, and a stage that held a Mac alone would be a ``GeometryReader`` with a
/// division in it rather than a drawing.
private struct MacDrawing<Screen: View>: View {
    /// The display's own height. The bezel, the lid, the base and the notch are all fractions of
    /// it or of the display's width, which follows from this one number.
    let displayHeight: CGFloat
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let displayWidth = displayHeight * MacStageMetrics.aspect
        let bezel = displayWidth * MacStageMetrics.bezel
        let lidWidth = displayWidth + bezel * 2
        let lidHeight = displayHeight + bezel * 2
        let baseHeight = lidWidth * MacStageMetrics.baseHeight
        let lid = UnevenRoundedRectangle(
            topLeadingRadius: lidWidth * MacStageMetrics.lidCorner,
            bottomLeadingRadius: lidWidth * MacStageMetrics.lidLowerCorner,
            bottomTrailingRadius: lidWidth * MacStageMetrics.lidLowerCorner,
            topTrailingRadius: lidWidth * MacStageMetrics.lidCorner,
            style: .continuous
        )

        VStack(spacing: 0) {
            lid
                .fill(MacStageMetrics.lid)
                .overlay {
                    screen()
                        .frame(width: displayWidth, height: displayHeight)
                        // Concentric with the lid, which is the site's own `--screen-r`: the
                        // screen's corner is the lid's less the bezel that surrounds it, so
                        // the black between the two is the same width all the way round.
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: lidWidth * MacStageMetrics.lidCorner - bezel,
                                style: .continuous
                            )
                        )
                        .overlay(alignment: .top) {
                            notch(width: displayWidth, height: displayHeight)
                        }
                }
                .frame(width: lidWidth, height: lidHeight)
                // The machined edge, drawn inside the body rather than around it, the same way
                // and for the same reason the phone's is.
                .overlay {
                    lid.strokeBorder(PhoneStageMetrics.rim, lineWidth: PhoneStageMetrics.rimWidth)
                }

            base(width: lidWidth * MacStageMetrics.baseOverhang, height: baseHeight)
        }
        .shadow(color: .black.opacity(0.62), radius: 26, y: 16)
    }

    private func notch(width: CGFloat, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: height * MacStageMetrics.notchCorner,
            bottomTrailingRadius: height * MacStageMetrics.notchCorner,
            style: .continuous
        )

        // Pure black, and nothing drawn on it. It carried a hairline of white at 16% down its
        // inside edge, on the reasoning that the housing is a black shape on a black bezel and
        // needs an edge to read as a cut rather than as a smudge. That is not what a notch looks
        // like: it is a hole in the display, nothing catches the light inside it face on, and the
        // line made it read as a shape laid on top of the screen instead of missing from it.
        //
        // It is the phone's island's own treatment, which has never had an edge either. The two
        // are the same thing on the same kind of glass, so they are drawn the same way, and what
        // tells the notch apart from the menu bar behind it is the menu bar, which is a capture of
        // a real desktop and is never this black.
        return shape
            .fill(.black)
            .frame(width: width * MacStageMetrics.notchWidth, height: height * MacStageMetrics.notchHeight)
    }

    private func base(width: CGFloat, height: CGFloat) -> some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: height * MacStageMetrics.baseCorner,
            bottomTrailingRadius: height * MacStageMetrics.baseCorner,
            style: .continuous
        )
        .fill(
            LinearGradient(
                colors: [MacStageMetrics.baseTop, MacStageMetrics.baseBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(width: width, height: height)
        // The lit hinge where the base meets the lid, so the two read as one machine rather than as
        // a screen standing on a bar.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MacStageMetrics.hinge)
                .frame(height: 1)
        }
        // The scoop in the front edge, centred and hung from the top of the base.
        .overlay(alignment: .top) {
            Capsule()
                .fill(MacStageMetrics.scoop)
                .frame(
                    width: width * MacStageMetrics.scoopWidth,
                    height: height * MacStageMetrics.scoopHeight
                )
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
    /// The displayed price, including the free row's explicit "No charge" label.
    let price: String
    let recommended: Bool
    let selected: Bool
    var features: [String] = []
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                if recommended {
                    Text("Best value")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(ColorPalette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(DisplayFont.display(21))
                        .tracking(-0.5)
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(price)
                        .font(DisplayFont.display(26))
                        .tracking(-0.8)
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }

                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !features.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(features, id: \.self) { feature in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(ColorPalette.ink.opacity(0.45))
                                    .frame(width: 10, alignment: .leading)

                                Text(feature)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .cardSurface()
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(ColorPalette.accent, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
