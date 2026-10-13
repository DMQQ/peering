import SwiftUI

/// The first screen the app shows, written for someone who has not decided yet. ``skip`` exists so a user who already knows what they want is one tap from the host list.
struct WelcomeFlow: View {
    var onFinish: () -> Void

    @State private var stage: Stage = .landing

    private enum Stage { case landing, tour }

    /// The landing leaves to the left, the way the tour's pages move. A cross-fade here read as no animation, since two thirds of the screen is identical before and after.
    private static let landingLeaves = AnyTransition.asymmetric(
        insertion: .opacity,
        removal: .move(edge: .leading).combined(with: .opacity)
    )
    private static let tourArrives = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .opacity
    )

    var body: some View {
        ZStack {
            switch stage {
            case .landing:
                WelcomeLanding(
                    onStart: { withAnimation(Motion.arrive) { stage = .tour } },
                    onSkip: onFinish
                )
                .transition(Self.landingLeaves)
            case .tour:
                OnboardingView(onFinish: onFinish)
                    .transition(Self.tourArrives)
            }
        }
        // Both stages are portrait; this stops the transition rotating halfway under a moving device.
        .preferredColorScheme(.dark)
    }
}

struct WelcomePrimaryButton: View {
    let title: String
    var action: () -> Void

    /// Taller and heavier than a stock control on purpose: at 44pt subheadline-semibold it read as a large link. Also applies to the paywall's buy button.
    private static let height: CGFloat = 54

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
        }
        .buttonStyle(WelcomeButtonStyle())
        // Swapping the title without animating keeps it a label change, not a button that shrinks and grows.
        .animation(nil, value: title)
    }
}

/// `.borderedProminent` eases its fill over 0.2s, which over white on near-black is almost nothing and reads as busy. This shrinks and hapticks immediately, then returns on a spring (the press lands; the release gives).
private struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ColorPalette.ink, in: Capsule())
            .foregroundStyle(ColorPalette.onInk)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.34, dampingFraction: 0.7),
                value: configuration.isPressed
            )
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in
                pressed
            }
    }
}

struct SkipButton: View {
    var action: () -> Void

    var body: some View {
        Button("Skip", action: action)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(RailButtonStyle(scale: 0.98))
            .padding(.horizontal, 18)
            .padding(.top, 6)
    }
}

#Preview {
    WelcomeFlow(onFinish: {})
        .preferredColorScheme(.dark)
}
