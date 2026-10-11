import SwiftUI

/// The landing's picture: remote control of the Mac in front, the Agents list behind it, and the three reasons it is safe to try hung around both. Control is the product, so it takes the front phone and the higher one.
struct WelcomeHero: View {
    private static let chips = [
        FloatingChip(symbol: "lock.shield", title: String(localized: "End-to-end encrypted"), alignment: .leading, y: 0.06),
        FloatingChip(symbol: "person.crop.circle.badge.xmark", title: String(localized: "No account"), alignment: .trailing, y: 0.5),
        FloatingChip(symbol: "wifi", title: String(localized: "Free on your own network"), alignment: .leading, y: 0.76)
    ]

    /// Both are fractions of one phone: how much of the back phone the front one covers, and how far the back one sits lower.
    private static let overlap: CGFloat = 0.3
    private static let drop: CGFloat = 0.07

    /// The pair is drawn a little larger than its box so its outer edges run off the screen: a device that fits exactly looks like a thumbnail.
    private static let bleed: CGFloat = 1.1

    var body: some View {
        GeometryReader { proxy in
            let metrics = PhoneStageMetrics.self
            let bodyWidthPerScreen = 1 + 2 * metrics.bezel
            let bodyHeightPerScreen = 1 / metrics.aspect + 2 * metrics.bezel

            let byWidth = proxy.size.width / (bodyWidthPerScreen * (2 - Self.overlap))
            let byHeight = proxy.size.height / (bodyHeightPerScreen * (1 + Self.drop))
            // Tilting grows each phone's footprint, so the pair is drawn a little under the box.
            let screenWidth = max(min(byWidth, byHeight) * 0.92, 1)

            let bodyWidth = screenWidth * bodyWidthPerScreen
            let bodyHeight = screenWidth * bodyHeightPerScreen

            ZStack(alignment: .topLeading) {
                // Only the picture is dimmed: dimming the whole phone took the rim with it, and the rim is faintest at the bottom, so the frame vanished there.
                PhoneDrawing(screenWidth: screenWidth) { screenshot("AppAgents").overlay(Color.black.opacity(0.3)) }
                    .rotationEffect(.degrees(-6))
                    .offset(y: bodyHeight * Self.drop)

                PhoneDrawing(screenWidth: screenWidth) { screenshot("AppControls") }
                    .rotationEffect(.degrees(4))
                    .offset(x: bodyWidth * (1 - Self.overlap))
            }
            .frame(width: bodyWidth * (2 - Self.overlap), height: bodyHeight * (1 + Self.drop), alignment: .topLeading)
            .scaleEffect(Self.bleed)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .overlay { FloatingChips(chips: Self.chips) }
        }
    }

    private func screenshot(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFill()
    }
}
