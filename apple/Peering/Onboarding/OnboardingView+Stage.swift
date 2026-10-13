import PeeringKit
import StoreKit
import SwiftUI
import UIKit

extension OnboardingView {
    // MARK: - The stage

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
                }
            }
        }
        // The download row is left out: it is on one page, and holding every page to its height left the others a gap above the buttons.
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(addressCopied ? "Address copied" : "Copy the download address")
    }

    var stage: some View {
        GeometryReader { proxy in
            let laid = stageLayout(in: proxy.size)

            ZStack {
                if case .mac = Self.pages[index].device {
                    MacDrawing(displayHeight: laid.macDisplay ?? 1) { deviceScreen }
                        .offset(laid.macOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

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
            .overlay {
                FloatingChips(chips: Self.pages[index].chips)
                    .id(index)
                    .transition(.opacity.animation(.easeOut(duration: 0.14)))
            }
        }
        .frame(height: stageHeight)
        .padding(.horizontal, 22)
        .animation(Motion.settle, value: index)
    }

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

        let macWidth = display * parts.macWidth
        let macHeight = display * parts.macHeight
        let macColumn = display * parts.macColumn
        let pairWidth = display * parts.width
        let pairHeight = display * parts.height

        laid.macDisplay = displayHeight
        laid.macOffset = CGSize(
            width: -pairWidth / 2 + macWidth / 2,
            height: pairHeight / 2 - macColumn + macHeight / 2
        )

        laid.phoneScale = display * MacAndPhoneMetrics.phoneScreen / alone
        laid.phoneOffset = CGSize(
            width: pairWidth / 2 - display * parts.phoneWidth / 2,
            height: pairHeight / 2 - display * parts.phoneHeight / 2
        )
        return laid
    }

    struct StageLayout {
        var macDisplay: CGFloat?
        var macOffset: CGSize = .zero

        var phoneScale: CGFloat = 1
        var phoneOffset: CGSize = .zero
    }

    var deviceScreen: some View {
        screen(for: index)
            .id(index)
            .transition(.opacity)
    }

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

    @ViewBuilder
    func companionScreen(_ screenshot: String) -> some View {
        picture(icon: "iphone", screenshot: screenshot)
            .id(screenshot)
            .transition(.opacity)
    }

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
