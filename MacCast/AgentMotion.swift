import SwiftUI

private struct AnimationsPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True under a page that is mounted but not shown: its lights and waves keep their place and stop drawing.
    var animationsPaused: Bool {
        get { self[AnimationsPausedKey.self] }
        set { self[AnimationsPausedKey.self] = newValue }
    }
}

/// A 30 frames a second clock for the agent screens' loops, stopped when Reduce Motion is on or the page is hidden.
struct LiveTick { let date: Date }

struct LiveTimeline<Content: View>: View {
    @Environment(\.animationsPaused) private var paused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: (LiveTick) -> Content

    init(@ViewBuilder content: @escaping (LiveTick) -> Content) {
        self.content = content
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused || reduceMotion)) { context in
            content(LiveTick(date: context.date))
        }
    }
}

/// Three dots passing a wave along, then the word. Timeline-driven: `repeatForever` started in `onAppear` dies on the first re-layout.
struct AgentThinkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()

    var body: some View {
        HStack(spacing: 9) {
            LiveTimeline { context in
                let t = context.date.timeIntervalSince(began)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        let wave = reduceMotion ? 0.5 : (sin(t * 5.2 - Double(index) * 0.9) + 1) / 2
                        Circle()
                            .fill(ColorPalette.ink)
                            .frame(width: 5, height: 5)
                            .opacity(0.3 + 0.6 * wave)
                            .offset(y: -3 * wave)
                    }
                }
            }
            Text("Working")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }
}

private struct RunningEdge: ViewModifier {
    let active: Bool
    let radius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active, !reduceMotion {
                LiveTimeline { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0), location: 0),
                                    .init(color: ColorPalette.ink, location: 0.12),
                                    .init(color: Color.white.opacity(0), location: 0.3),
                                    .init(color: Color.white.opacity(0), location: 1)
                                ],
                                center: .center,
                                angle: .degrees(turn * 360)
                            ),
                            lineWidth: 1.2
                        )
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(Motion.tap, value: active)
    }
}

private struct BreathingStroke: ViewModifier {
    let colour: Color
    let radius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            LiveTimeline { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let breath = reduceMotion ? 0.5 : (sin(t * 2.6) + 1) / 2
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(colour.opacity(0.18 + 0.5 * breath), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// A light travelling round the outline while `active`.
    func runningEdge(_ active: Bool, radius: CGFloat) -> some View {
        modifier(RunningEdge(active: active, radius: radius))
    }

    /// An outline that slowly brightens and dims, for something waiting on the person.
    func breathingStroke(_ colour: Color, radius: CGFloat) -> some View {
        modifier(BreathingStroke(colour: colour, radius: radius))
    }

    /// A new row rises into place instead of appearing.
    func agentRowArrival() -> some View {
        transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.97, anchor: .bottomLeading)),
                removal: .opacity
            )
        )
    }
}

/// Floats a view a few points and breathes its scale, so an empty chat is not a still frame.
struct AgentIdleFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        LiveTimeline { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            content
                .offset(y: sin(t * 1.5) * 4)
                .scaleEffect(1 + sin(t * 1.5 + 1) * 0.015)
        }
    }
}
