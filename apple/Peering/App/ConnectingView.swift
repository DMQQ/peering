import PeeringKit
import RemoteCore
import StoreKit
import SwiftUI
import UIKit

/// The screen shown while a connection is being made. A slow attempt says so and offers a way out, a failure says what went wrong and stays until read, and success shows a checkmark before the reveal.
struct ConnectingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let hostName: String?
    var failure: String?
    var isSlow: Bool
    /// True only after an already-paired Mac reaches `.ready`; first-time pairing moves on to its code, so it never claims success before confirmation.
    var isConnected: Bool
    var onDismiss: () -> Void
    var onCancel: () -> Void

    @State private var stepIndex = 0

    private static let steps = [
        String(localized: "Establishing connection…"),
        String(localized: "Exchanging keys…"),
        String(localized: "Opening your screen…"),
    ]
    private static let stepDuration: Duration = .milliseconds(420)

    private var rollAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.85)
    }

    private var arrivalAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.46, dampingFraction: 0.5)
    }

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()

            TopGlow()

            VStack(spacing: 26) {
                // The slot is a fixed height so a failure does not shift the name and sentence under it.
                ZStack {
                    if failure == nil {
                        DeviceLinkArtwork(scale: 1.8)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(ColorPalette.ink)
                            .transition(.opacity)
                    }
                }
                .frame(height: 92)

                VStack(spacing: 7) {
                    Text(hostName ?? String(localized: "Your Mac"))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(detail)
                        .id(detail)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                )
                        )
                        .font(.subheadline)
                        .foregroundStyle(
                            failure == nil
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(ColorPalette.ink.opacity(0.85))
                        )
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .clipped()
                .animation(rollAnimation, value: detail)

                if let failure {
                    Button("Dismiss", action: onDismiss)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(ColorPalette.ink)
                        .foregroundStyle(.black)
                        .accessibilityHint(failure)
                } else if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(ColorPalette.accent)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.2))
                        )
                        .accessibilityLabel("Connected")
                } else if isSlow {
                    Button("Give up", action: onCancel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .buttonStyle(RailButtonStyle(scale: 0.98))
                } else {
                    ConnectingComet()
                }
            }
            .padding(.horizontal, 40)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: failure != nil)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: isSlow)
            .animation(arrivalAnimation, value: isConnected)
        }
        .allowsHitTesting(true)
        .task {
            while stepIndex < Self.steps.count - 1 {
                try? await Task.sleep(for: Self.stepDuration)
                guard !Task.isCancelled else { return }
                stepIndex += 1
            }
        }
    }

    private var detail: String {
        if let failure { return failure }
        if isConnected { return String(localized: "Connected") }
        return isSlow
            ? String(localized: "Still trying. The Mac has not answered yet.")
            : Self.steps[stepIndex]
    }
}
