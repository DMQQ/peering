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

                if let failure {
                    Button("Dismiss", action: onDismiss)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(ColorPalette.ink)
                        .foregroundStyle(.black)
                        .accessibilityHint(failure)
                } else if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(ColorPalette.accent)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.92))
                        )
                        .accessibilityLabel("Connected")
                } else if isSlow {
                    Button("Give up", action: onCancel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .buttonStyle(RailButtonStyle(scale: 0.98))
                } else {
                    ConnectingSpinner()
                }
            }
            .padding(.horizontal, 40)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: failure != nil)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: isSlow)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: isConnected)
        }
        .allowsHitTesting(true)
    }

    private var detail: String {
        if let failure { return failure }
        if isConnected { return String(localized: "Connected") }
        return isSlow
            ? String(localized: "Still trying. The Mac has not answered yet.")
            : String(localized: "Connecting…")
    }
}

/// `repeatForever` on the shape itself, not an ancestor: an ancestor's repeating animation captures the layout of everything beneath it (see ``DeviceLinkArtwork``).
private struct ConnectingSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(ColorPalette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}
