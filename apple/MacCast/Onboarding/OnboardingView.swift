import MacCastKit
import StoreKit
import SwiftUI
import UIKit

struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(StoreManager.self) var store

    @State var index = 0
    @State var stageHeight: CGFloat = 0
    @State var tallestWords: CGFloat = 0
    @State var contentVisible = false
    @State var chosen: PlanOffer? = .subscription

    @State var addressCopied = false

    @State var restoreNote: String?

    static var freeLine: String {
        let line = String(localized: "\(RelayPlan.free.allowanceSpelling) a day away from your own network")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    static let bodyHeight: CGFloat = 124

    static let pages: [Page] = [
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppMac"),
            title: String(localized: "Install it once"),
            body: """
                Put Peering on the Mac you want to reach and open it. That is the whole setup: \
                no account, router changes, or settings to configure.
                """,
            device: .mac(companion: "AppConnect"),
            chips: [
                FloatingChip(symbol: "checkmark.circle", title: String(localized: "One-time setup"), alignment: .leading, y: 0.2),
                FloatingChip(symbol: "person.crop.circle.badge.xmark", title: String(localized: "No account"), alignment: .trailing, y: 0.76)
            ]
        ),
        Page(
            content: .feature(icon: "wifi", screenshot: "AppConnect"),
            title: String(localized: "Pair once. Stay connected."),
            body: """
                Choose your Mac, compare the six-digit code, and Peering remembers it. Next time, \
                reconnect nearby or from another network without pairing again.
                """,
            chips: [
                FloatingChip(symbol: "lock.shield", title: String(localized: "Six-digit code"), alignment: .leading, y: 0.18),
                FloatingChip(symbol: "arrow.triangle.2.circlepath", title: String(localized: "Reconnects itself"), alignment: .trailing, y: 0.62)
            ]
        ),
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppSources"),
            title: String(localized: "See exactly what you need"),
            body: """
                Bring over a whole display, one app, a single window, or any of your Spaces. Jump \
                between them whenever you like without ending the session.
                """,
            chips: [
                FloatingChip(symbol: "display", title: String(localized: "Whole display"), alignment: .leading, y: 0.14),
                FloatingChip(symbol: "macwindow", title: String(localized: "Single window"), alignment: .trailing, y: 0.46),
                FloatingChip(symbol: "square.stack.3d.up", title: String(localized: "Any Space"), alignment: .leading, y: 0.76)
            ]
        ),
        Page(
            content: .feature(icon: "hand.point.up.left", screenshot: "AppControls"),
            title: String(localized: "Your Mac, under your fingers"),
            body: """
                Tap, type, scroll, zoom, use shortcuts, or steer the pointer with the joystick. \
                Switch to Observe whenever you only want to look.
                """,
            chips: [
                FloatingChip(symbol: "cursorarrow.motionlines", title: String(localized: "Joystick pointer"), alignment: .leading, y: 0.2),
                FloatingChip(symbol: "command", title: String(localized: "Shortcuts"), alignment: .trailing, y: 0.5),
                FloatingChip(symbol: "eye", title: String(localized: "Observe mode"), alignment: .leading, y: 0.78)
            ]
        ),
        Page(
            content: .feature(icon: "arrow.triangle.2.circlepath", screenshot: "AppPictureInPicture"),
            title: String(localized: "Your session follows you"),
            body: """
                Leave the app or lock your phone without losing the connection. Picture in Picture \
                keeps your Mac in view, while Live Activities keep the session close at hand.
                """,
            chips: [
                FloatingChip(symbol: "pip", title: String(localized: "Picture in Picture"), alignment: .leading, y: 0.2),
                FloatingChip(symbol: "lock.iphone", title: String(localized: "Live Activity"), alignment: .trailing, y: 0.62)
            ]
        ),
        Page(
            content: .feature(icon: "square.grid.2x2", screenshot: "AppMosaic"),
            title: String(localized: "See everything at once"),
            body: """
                Lay out windows, apps and displays side by side and watch them all live. Tap any \
                tile to take control, and come back to the arrangement when you are done.
                """,
            chips: [
                FloatingChip(symbol: "square.grid.2x2", title: String(localized: "Live tiles"), alignment: .trailing, y: 0.18),
                FloatingChip(symbol: "hand.tap", title: String(localized: "Tap to take control"), alignment: .leading, y: 0.66)
            ]
        ),
        Page(
            content: .notification,
            title: String(localized: "Told when a shell is waiting"),
            body: """
                A build that finishes, a prompt for a password, a command that wants an answer: \
                the Mac tells you, on the Lock Screen and with the app closed.
                """,
            chips: [
                FloatingChip(symbol: "lock.iphone", title: String(localized: "Lock Screen"), alignment: .leading, y: 0.12),
                FloatingChip(symbol: "bell.badge", title: String(localized: "App closed, still told"), alignment: .trailing, y: 0.5)
            ]
        ),
        Page(
            content: .plans,
            title: String(localized: "Start free. Go farther when you need."),
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
        .onChange(of: index, initial: true) { _, page in Analytics.onboardingPage(page) }
    }

    var compactWidthBody: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { offset, page in
                        pageView(page, at: offset).tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background { wordsRuler }
                // It keeps the whole of the swipe area with it. Drawn beside the pages instead of
                // over them, a frame that is not a page takes the top two thirds of the screen out
                // of the gesture, and the tour would only be swipeable by the two lines of text it
                // is about.
                .overlay(alignment: .top) { stage }

                indicator
                actions
            }

            if !showsPlans {
                SkipButton(action: skip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    var regularWidthBody: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

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
                .overlay {
                    FloatingChips(chips: Self.pages[index].chips)
                        .id(index)
                        .transition(.opacity.animation(.easeOut(duration: 0.14)))
                }
                .position(x: proxy.size.width - 48 - columnWidth / 2, y: proxy.size.height / 2)
                .animation(Motion.settle, value: index)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    func pageView(_ page: Page, at offset: Int) -> some View {
        let here = offset == index
        let shown = here ? contentVisible : true

        if case .plans = page.content {
            plansPage(page, shown: shown, lit: here)
        } else {
            devicePage(page, shown: shown, lit: here)
        }
    }

    func plansPage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(page.title, lit: lit)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .animation(motion(delay: 0.09), value: shown)

            PlansHero()
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .opacity(shown ? 1 : 0)
                .animation(motion(delay: 0.16), value: shown)

            plans

            legalLinks
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

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
        .frame(maxWidth: .infinity)
    }

    func devicePage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    stageHeight = height
                }

            // Held because the stage above them takes whatever is left: without it the shortest
            // page's title sits a line lower than the tallest page's, and swiping the tour moves
            // the heading up and down by the difference. A minimum rather than a fixed height, so
            // a longer body — the reader's own text size, in the end — grows the text instead of
            // being cut off by it.
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

    func skip() {
        Analytics.onboardingSkipped(atPage: index)
        guard !store.isPro else { return onFinish() }
        withAnimation(Motion.settle) { index = Self.pages.count - 1 }
    }

    var showsPlans: Bool { isLast && !store.isPro }

    var primaryTitle: String {
        guard showsPlans else { return isLast ? String(localized: "Get started") : String(localized: "Next") }

        guard let chosen, let title = store.buttonTitle(for: chosen) else { return String(localized: "Start using Peering") }

        if store.isPurchasing { return String(localized: "Contacting the App Store…") }
        return title
    }

    func primaryAction() {
        guard showsPlans, let chosen,
              let product = store.product(for: chosen)
        else {
            advance()
            return
        }

        Task {
            await store.purchase(product)
            if store.isPro {
                Analytics.onboardingCompleted()
                onFinish()
            }
        }
    }

    /// A page swiped in has already been seen arriving — it moved, and it did it under the user's
    /// finger — so its contents are left alone. A page the button moves to arrives with the whole
    /// screen sliding sideways, and the contents coming up inside it afterwards is the difference
    /// between turning a page and watching the page that was already there be replaced.
    func advance() {
        guard !isLast else {
            Analytics.onboardingCompleted()
            onFinish()
            return
        }
        revealContent()
        withAnimation(Motion.arrive) { index += 1 }
    }

    struct Page {
        let content: Content
        let title: String
        let body: String

        var device: Device = .phone

        var chips: [FloatingChip] = []

        enum Device {
            case phone
            case mac(companion: String)
        }

        enum Content {
            case feature(icon: String, screenshot: String? = nil, tabletScreenshot: String? = nil)
            case notification
            case plans

            var wordsAreHeld: Bool {
                switch self {
                case .feature, .notification: return true
                case .plans: return false
                }
            }
        }
    }
}
