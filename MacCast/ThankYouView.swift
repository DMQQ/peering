import StoreKit
import SwiftUI

/// What the app shows when a subscription purchase completes.
///
/// Presented as a full-screen overlay over the paywall, so the purchase has its own moment
/// rather than the paywall rewriting itself. The icon springs in first, then the text lifts and
/// fades up in sequence, giving the confirmation a pace that reads as arrival rather than
/// replacement.
struct ThankYouView: View {
    let tier: StoreManager.Tier
    let onDismiss: () -> Void

    @State private var iconVisible = false
    @State private var contentVisible = false

    var body: some View {
        ZStack(alignment: .leading) {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            VStack(alignment: .leading, spacing: 24) {
                icon

                VStack(alignment: .leading, spacing: 8) {
                    Text("You are on \(tier.name).")
                        .font(DisplayFont.display(34))
                        .tracking(-1.2)
                        .opacity(contentVisible ? 1 : 0)
                        .offset(y: contentVisible ? 0 : 12)
                        .animation(Motion.arrive, value: contentVisible)

                    Text(tier.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(contentVisible ? 1 : 0)
                        .offset(y: contentVisible ? 0 : 8)
                        .animation(Motion.arrive.delay(0.1), value: contentVisible)
                }

                featureList
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : 8)
                    .animation(Motion.arrive.delay(0.2), value: contentVisible)

                WelcomePrimaryButton(title: String(localized: "Start using Peering")) { onDismiss() }
                    .padding(.top, 8)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : 8)
                    .animation(Motion.arrive.delay(0.3), value: contentVisible)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Renews automatically. Cancel any time in your App Store settings.")
                        .fixedSize(horizontal: false, vertical: true)

                    // Markdown link so the address is tappable inline rather than a separate row.
                    Text("Questions or suggestions? [support@getpeering.app](mailto:support@getpeering.app)")
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(Color(white: 1, opacity: 0.46))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(contentVisible ? 1 : 0)
                .animation(Motion.arrive.delay(0.36), value: contentVisible)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .onAppear {
            withAnimation(Motion.morph) { iconVisible = true }
            withAnimation(Motion.arrive.delay(0.18)) { contentVisible = true }
        }
    }

    private var icon: some View {
        ZStack {
            Circle()
                .fill(ColorPalette.accent.opacity(0.10))
                .frame(width: 84, height: 84)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(ColorPalette.accent)
        }
        .scaleEffect(iconVisible ? 1 : 0.4)
        .opacity(iconVisible ? 1 : 0)
        .animation(Motion.morph, value: iconVisible)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tier.features.prefix(4), id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ColorPalette.ink.opacity(0.45))
                        .frame(width: 10, alignment: .leading)
                    Text(feature)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#Preview {
    ThankYouView(tier: .pro, onDismiss: {})
        .preferredColorScheme(.dark)
}
