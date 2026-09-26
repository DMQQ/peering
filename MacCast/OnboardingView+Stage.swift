import MacCastKit
import StoreKit
import SwiftUI
import UIKit

extension OnboardingView {
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
    static var measuredPages: [Page] {
        Self.pages.filter { $0.content.wordsAreHeld }
    }

    var wordsRuler: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.measuredPages.enumerated()), id: \.offset) { _, page in
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.title)
                        .font(DisplayFont.display(.largeTitle))
                        .tracking(-1)

                    if page.content.wordsAreHeld {
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
    var downloadLink: some View {
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
    var copyAddress: some View {
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
    var stage: some View {
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
    func stageLayout(in box: CGSize) -> StageLayout {
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
    struct StageLayout {
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
    var deviceScreen: some View {
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
    var phoneScreen: some View {
        if case .mac(let companion) = Self.pages[index].device {
            companionScreen(companion)
        } else {
            deviceScreen
        }
    }

    /// What the tablet frame holds on regular-width layouts.
    ///
    /// Prefers the page's `tabletScreenshot` when one exists, and falls back to the phone screenshot
    /// so that a page without a tablet capture yet is not left with a glyph on iPad while it has a
    /// real picture on iPhone.
    @ViewBuilder
    var tabletScreen: some View {
        switch Self.pages[index].content {
        case .feature(let icon, let screenshot, let tabletScreenshot):
            picture(icon: icon, screenshot: tabletScreenshot ?? screenshot)
                .id(index)
                .transition(.opacity)
        case .notification:
            NotificationBanner()
                .id(index)
                .transition(.opacity)
        case .plans:
            Color.black
        }
    }

    /// What the device is holding while a given page is on screen.
    ///
    /// The frame is the constant and this is the variable, which is the same arrangement the file
    /// used to describe from the other end: the shape of the app is the same from the first page to
    /// the last, and each page's picture lands inside it.
    @ViewBuilder
    func screen(for offset: Int) -> some View {
        switch Self.pages[offset].content {
        case .feature(let icon, let screenshot, _):
            picture(icon: icon, screenshot: screenshot)

        case .notification:
            NotificationBanner()

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
    func companionScreen(_ screenshot: String) -> some View {
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
    func picture(icon: String, screenshot: String?) -> some View {
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
    func placeholder(_ symbol: String) -> some View {
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
}
