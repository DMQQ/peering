import SwiftUI

/// Rings that leave the devices one after another and fade as they spread, in the palette's white only.
struct ConnectingPulse: View {
    private static let ringCount = 3
    private static let period = 2.8

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = min(size.width, size.height) / 2
                for index in 0..<Self.ringCount {
                    let progress = (now / Self.period + Double(index) / Double(Self.ringCount))
                        .truncatingRemainder(dividingBy: 1)
                    let eased = 1 - pow(1 - progress, 2)
                    let radius = reach * (0.35 + 0.65 * eased)
                    let ring = Path(ellipseIn: CGRect(
                        x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
                    ))
                    canvas.stroke(ring, with: .color(.white.opacity(0.22 * (1 - progress))), lineWidth: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A bright head with a fading tail that circles, so the wait reads as something travelling rather than a fixed arc turning.
struct ConnectingComet: View {
    private static let turn = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((now / Self.turn).truncatingRemainder(dividingBy: 1) * 360)
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: 0.45)
                    .stroke(
                        AngularGradient(
                            colors: [.white.opacity(0), .white],
                            center: .center,
                            startAngle: .zero,
                            endAngle: .degrees(162)
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(angle)
            }
            .frame(width: 30, height: 30)
        }
        .accessibilityHidden(true)
    }
}
