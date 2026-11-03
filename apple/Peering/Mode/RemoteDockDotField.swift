import SwiftUI

/// The pad's texture: a field of small dots under a slow drifting swell, which bulge and brighten around the finger and send a ripple out where a touch lands.
struct RemoteDockDotField: View {
    let touch: CGPoint?
    /// Where the latest touch landed and when; each new one sends a ring out.
    let ripple: RemoteDockRipple?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spacing: CGFloat = 14
    private static let reach: CGFloat = 90
    private static let rippleSeconds = 0.7
    private static let rippleSpeed: CGFloat = 420

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let columns = Int(size.width / Self.spacing)
        let rows = Int(size.height / Self.spacing)
        let insetX = (size.width - CGFloat(columns) * Self.spacing) / 2 + Self.spacing / 2
        let insetY = (size.height - CGFloat(rows) * Self.spacing) / 2 + Self.spacing / 2
        let time = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
        for row in 0..<rows {
            for column in 0..<columns {
                let center = CGPoint(x: insetX + CGFloat(column) * Self.spacing, y: insetY + CGFloat(row) * Self.spacing)
                let swell = 0.5 + 0.5 * sin(time * 1.1 - Double(center.x + center.y * 0.6) * 0.018)
                let lift = max(closeness(of: center), rippleLift(at: center, now: now))
                let radius = 1.1 + CGFloat(swell) * 0.35 + lift * 2.2
                let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let opacity = 0.17 + swell * 0.1 + Double(lift) * 0.58
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(opacity)))
            }
        }
    }

    /// 1 under the finger, falling smoothly to 0 at `reach`.
    private func closeness(of point: CGPoint) -> CGFloat {
        guard let touch else { return 0 }
        return Self.falloff(hypot(point.x - touch.x, point.y - touch.y), width: Self.reach)
    }

    /// A ring travelling out from where the last touch landed, fading as it goes.
    private func rippleLift(at point: CGPoint, now: Date) -> CGFloat {
        guard !reduceMotion, let ripple else { return 0 }
        let age = now.timeIntervalSince(ripple.start)
        guard age < Self.rippleSeconds else { return 0 }
        let radius = CGFloat(age) * Self.rippleSpeed
        let distance = abs(hypot(point.x - ripple.point.x, point.y - ripple.point.y) - radius)
        return Self.falloff(distance, width: 22) * CGFloat(1 - age / Self.rippleSeconds) * 0.7
    }

    private static func falloff(_ distance: CGFloat, width: CGFloat) -> CGFloat {
        guard distance < width else { return 0 }
        let t = 1 - distance / width
        return t * t * (3 - 2 * t)
    }
}

struct RemoteDockRipple {
    let point: CGPoint
    let start: Date
}
