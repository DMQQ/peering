import SwiftUI

/// The top of the plans page: the app's own screen in the tour's phone, rising out of the bottom edge, with what Pro adds floating around it.
struct PlansHero: View {
    private static let chips = [
        FloatingChip(symbol: "infinity", title: String(localized: "Unlimited time away"), alignment: .leading, y: 0.2),
        FloatingChip(symbol: "sparkles", title: String(localized: "Sharpest picture"), alignment: .trailing, y: 0.42),
        FloatingChip(symbol: "network", title: String(localized: "Any network"), alignment: .leading, y: 0.7)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let screenWidth = size.height * 1.5 * PhoneStageMetrics.aspect

            PhoneDrawing(screenWidth: screenWidth) {
                Image("AppConnect")
                    .resizable()
                    .scaledToFill()
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .mask(
                LinearGradient(
                    stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .accessibilityHidden(true)
            .overlay { FloatingChips(chips: Self.chips) }
        }
        .clipped()
    }
}
