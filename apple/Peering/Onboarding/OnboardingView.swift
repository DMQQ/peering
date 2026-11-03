import PeeringKit
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
            // a longer body, the reader's own text size, in the end, grows the text instead of
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

    /// A page swiped in has already been seen arriving, it moved, and it did it under the user's
    /// finger, so its contents are left alone. A page the button moves to arrives with the whole
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
}
