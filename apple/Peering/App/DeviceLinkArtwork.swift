import PeeringKit
import RemoteCore
import StoreKit
import SwiftUI
import UIKit

/// `scale` multiplies every measurement so there is one drawing, not two sets of proportions. The devices are `MacDrawing` and `PhoneDrawing` at icon size, so the app has one drawing of each machine.
struct DeviceLinkArtwork: View {
    var scale: CGFloat = 1

    var body: some View {
        // Twenty frames a second is enough for a slow drift and pulse. A TimelineView rather than `repeatForever`, which a re-layout cancels (see ``Wordmark`` in `HostPickerView`).
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10 * scale) {
                mac.offset(y: wave(now, period: 5.2) * 1.6 * scale)
                dots(at: now)
                phone.offset(y: wave(now, period: 6.4, phase: 0.35) * 1.6 * scale)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var mac: some View {
        MacDrawing(displayHeight: 24 * scale) {
            ColorPalette.surface
                .overlay {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 9 * scale, weight: .medium))
                        .foregroundStyle(ColorPalette.ink)
                }
        }
    }

    private var phone: some View {
        PhoneDrawing(screenWidth: 19 * scale) {
            ColorPalette.surface
        }
    }

    private func dots(at now: TimeInterval) -> some View {
        HStack(spacing: 4 * scale) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(ColorPalette.ink)
                    .frame(width: 3 * scale, height: 3 * scale)
                    .opacity(
                        0.42 + 0.42 * wave(
                            now,
                            period: 1.5,
                            phase: -Double(index) * (0.25 / 1.5)
                        )
                    )
            }
        }
    }

    private func wave(_ now: TimeInterval, period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin(2 * .pi * (now / period + phase)))
    }
}
