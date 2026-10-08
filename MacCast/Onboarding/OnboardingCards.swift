import MacCastKit
import StoreKit
import SwiftUI
import UIKit

/// The type runs roughly a fifth larger than a real notification's. The tour draws a phone about
/// 200 points wide, where an honest 13-point app name is seven points and the weight that separates
/// it from the title stops reading.
struct NotificationBanner: View {
    static let examples = [
        Example(
            title: String(localized: "Build finished"),
            body: String(localized: "Damian's MacBook Pro: `xcodebuild` completed successfully."),
            age: "now"
        ),
        Example(
            title: String(localized: "Terminal needs you"),
            body: String(localized: "Damian's MacBook Pro: Terminal “prod” is waiting for a password."),
            age: "2m"
        ),
        Example(
            title: String(localized: "Command needs an answer"),
            body: String(localized: "Damian's MacBook Pro: Terminal is waiting for your input."),
            age: "8m"
        )
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .top) {
                Image("NotificationWallpaper")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.04), .black.opacity(0.20)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: width * 0.005) {
                    Text("Wednesday, September 24")
                        .font(.system(size: width * 0.036, weight: .semibold))

                    Text("9:41")
                        .font(.system(size: width * 0.175, weight: .thin))
                        .tracking(-width * 0.006)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.16), radius: width * 0.012, y: width * 0.006)
                .padding(.top, proxy.size.height * 0.075)

                VStack(spacing: width * 0.025) {
                    ForEach(Self.examples) { example in
                        card(example, width: width)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, proxy.size.height * 0.075)
            }
        }
        // The page's own words say this, and a notification read aloud is one this reader never got.
        .accessibilityHidden(true)
    }

    func card(_ example: Example, width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.055, style: .continuous)
        let tile = width * 0.085

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: width * 0.025) {
                icon(tile)

                Text("Peering")
                    .font(.system(size: width * 0.038, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink.opacity(0.70))

                Spacer(minLength: width * 0.02)

                Text(example.age)
                    .font(.system(size: width * 0.033))
                    .foregroundStyle(ColorPalette.ink.opacity(0.55))
            }

            Text(example.title)
                .font(.system(size: width * 0.040, weight: .semibold))
                .foregroundStyle(ColorPalette.ink)
                .padding(.top, width * 0.014)

            Text(example.body)
                .font(.system(size: width * 0.033))
                .foregroundStyle(ColorPalette.ink.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, width * 0.003)
        }
        .lineLimit(1)
        .padding(.horizontal, width * 0.035)
        .padding(.vertical, width * 0.023)
        .frame(width: width * 0.92, alignment: .leading)
        .background {
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(0.09), .white.opacity(0.045)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.20), .white.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
    }

    func icon(_ size: CGFloat) -> some View {
        Image(String(localized: "Pears"))
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.85)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .fill(ColorPalette.backdrop)
            }
    }

    struct Example: Identifiable {
        let title: String
        let body: String
        let age: String

        var id: String { title }
    }
}

// MARK: - Plan choice

struct PlanChoice: View {
    let name: String
    let line: String
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
