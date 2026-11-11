import SwiftUI

/// A bright head with a fading tail that circles, driven from a `TimelineView` because a `repeatForever` is cancelled by a re-layout.
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
