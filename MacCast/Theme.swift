import MacCastKit
import SwiftUI

enum ChromeMetrics {
    static let panelWidth: CGFloat = 54
    static let cornerRadius: CGFloat = 20
    /// A capsule's corner is half its height and cut into the controls of a three-row pill, so the pill takes two radii instead.
    static let pillCollapsedRadius: CGFloat = 30
    static let pillExpandedRadius: CGFloat = 26
    static let statusBarMaxWidth: CGFloat = 460
    static let railPadding: CGFloat = 4
    static let railSidePadding: CGFloat = 4
    static let edgeInset: CGFloat = 8
    static let bottomInset: CGFloat = 22
    static let panelGap: CGFloat = 8
    /// The landscape side margin the picture keeps clear of the rails. Applied to the bounds the picture is laid out in, not the video alone, because every window rect is measured against the rectangle the pixels are drawn in.
    static let pictureInset: CGFloat = 0.125
    static let buttonGap: CGFloat = 2
    static let panelPadding: CGFloat = 5
    /// Taller than wide: square left the icon and caption fighting for height.
    static let buttonHeight: CGFloat = 62
    static let wheelHeight: CGFloat = 120
    static let quickKeySize: CGFloat = 60

    static let dockColumns = 5
    static let dockExpandedRows = 3

    static let dockToggleWidth: CGFloat = 52

    static let dockCollapsedHeight = buttonHeight + railPadding * 2

    /// Split out because the pager is given exactly this much; handed the whole card it would page by the wrong amount.
    static let dockExpandedGridHeight = buttonHeight * CGFloat(dockExpandedRows)
        + buttonGap * CGFloat(dockExpandedRows - 1)

    static let dockExpandedHeight = dockExpandedGridHeight + railPadding * 2

    static let dockPageDotsHeight: CGFloat = 10

    static let dockDotsGap: CGFloat = 6

    /// Card and dots together: what a panel above must stay clear of.
    static let dockStandingHeight = dockExpandedHeight + dockDotsGap + dockPageDotsHeight

    static let dockCollapsedRadius: CGFloat = dockCollapsedHeight / 2
    static let dockExpandedRadius: CGFloat = 28

    static let dockWidthFraction: CGFloat = 0.9
}

enum Motion {
    /// The spring behind ``settle`` as numbers: the picture's zoom and pan are a `UIView` layer transform written per frame, so the curve must be evaluated, not handed to SwiftUI.
    static let settleResponse: Double = 0.34
    static let settleDamping: Double = 0.84

    static let pictureResponse: Double = 0.24

    static let settle = Animation.spring(response: settleResponse, dampingFraction: settleDamping)

    /// The spring's own solution, so a movement outside the animation system matches. Damping of 1 or more is treated as 1 (critically damped).
    static func settleProgress(
        at time: Double,
        response: Double = settleResponse,
        damping: Double = settleDamping
    ) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = min(max(damping, 0), 1)
        guard zeta < 1 else {
            return 1 - exp(-omega * time) * (1 + omega * time)
        }
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * time)
            * (cos(damped * time) + (zeta * omega / damped) * sin(damped * time))
    }

    static let tap = Animation.smooth(duration: 0.18)

    /// Critically damped: give in a dozen staggered pieces would leave the last frames disagreeing about which way is down.
    static let arrive = Animation.spring(response: 0.52, dampingFraction: 1)

    /// Two curves so the mark does not take the diagonal. They must share a duration or the mark lands, moves again and lands.
    static let travel = Animation.timingCurve(0.3, 0.6, 0.32, 1, duration: 0.88)
    static let rise = Animation.timingCurve(0.55, 0.12, 0.32, 1, duration: 0.88)

    /// Less damped than `settle`: the overshoot past the final size is the effect, and the give must scale with the distance travelled.
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.68)
}

enum ColorPalette {
    static let ink = Color.white
    static let onInk = Color.black
    /// The one colour in the app: marks what is on and nothing else uses it. System blue because it already means selected on the phone.
    static let accent = Color.blue

    static let selectedFill = Color.blue

    /// A fade alone cannot show a press over video: dimming a white glyph reads as switching off.
    static let pressedFill = Color.white.opacity(0.22)

    static let danger = Color(red: 0.98, green: 0.45, blue: 0.40)
    static let caution = Color(red: 0.97, green: 0.75, blue: 0.35)
    static let surface = Color.white.opacity(0.07)
    /// Near-black rather than black: pure #000 next to a video's blacks makes the picture look inset.
    static let backdrop = Color(red: 0.04, green: 0.04, blue: 0.045)

    /// Heavy on purpose: the backdrop is a picture that can be anything, and a thin frost over a blank document lands within points of ``ink``. The one number to turn if the fallback reads wrong.
    static let glassTint = backdrop.opacity(0.70)

    static func reading(_ milliseconds: Double) -> Color {
        // Hue rather than brightness, the one break from the palette's rule: three shades of white at arm's length are one shade.
        // Bands live in ``LatencyQuality``, which also drives the pill's word: one set of thresholds.
        switch LatencyQuality.of(milliseconds: milliseconds) {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        }
    }
}

struct TopGlow: View {
    var body: some View {
        RadialGradient(
            colors: [.white.opacity(0.07), .clear],
            center: .top,
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct AppBackdrop: View {
    var body: some View {
        ZStack {
            ColorPalette.backdrop
            TopGlow()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The one place the display face is named, so a change of face is one edit.
enum DisplayFont {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }

    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, design: .serif).weight(.bold)
    }
}

/// `.font()` is discrete; `Animatable` re-renders at each frame's size so a resizing label glides with the rest.
struct AnimatableDisplay: ViewModifier, Animatable {
    var size: CGFloat
    var tracking: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size, tracking) }
        set {
            size = newValue.first
            tracking = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .font(DisplayFont.display(size))
            .tracking(tracking)
    }
}

struct IconTile: View {
    let symbol: String
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.405, weight: .medium))
            .foregroundStyle(ColorPalette.ink)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.286, style: .continuous)
                    .fill(ColorPalette.ink.opacity(0.12))
            }
    }
}

struct Wordmark: View {
    let size: CGFloat
    let tracking: CGFloat

    var body: some View {
        Text("Peering")
            .modifier(AnimatableDisplay(size: size, tracking: tracking))
            .sheen()
    }
}

private struct Sheen: ViewModifier {
    /// Whether the light is running. A page-style `TabView` builds neighbouring pages, so without this a heading would run timelines behind unseen pages.
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Light crossing light is nothing, so this paints as well as lights.
    static let paint: CGFloat = 0.78

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ColorPalette.ink.opacity(Self.paint))
            .overlay {
                if active, !reduceMotion {
                    Sweep { content }
                }
            }
    }

    /// Its own view so the clock starts when the light does: `@State` on the modifier survives stop and start, so a returning page resumed mid-cycle with a band in the middle of the name.
    private struct Sweep<Mask: View>: View {
        @ViewBuilder var mask: () -> Mask

        /// When the light started, so the sweep begins on the frame the name does.
        @State private var began = Date()

        private static var crossing: TimeInterval { 1.6 }
        private static var cycle: TimeInterval { 4.2 }

        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                // A timeline rather than `repeatForever` from `onAppear`: a re-layout cancels the repeat and `onAppear` never refires, leaving a sweep that ran once and stopped.
                TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                    band(width: width, height: height, elapsed: context.date.timeIntervalSince(began))
                }
                .mask { mask() }
            }
            .allowsHitTesting(false)
        }

        private func band(width: CGFloat, height: CGFloat, elapsed: TimeInterval) -> some View {
            // The crossing is the first two fifths of a cycle, so the light pauses off either end rather than looping.
            let progress = min(max(elapsed.truncatingRemainder(dividingBy: Self.cycle) / Self.crossing, 0), 1)
            return LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.9), location: 0.5),
                    .init(color: .white.opacity(0), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // A third of the name wide: narrower reads as a scanning bar, wider has no edge.
            .frame(width: width * 0.34, height: height)
            .offset(x: (progress * 3 - 1.5) * width)
            .frame(width: width, height: height)
        }
    }
}

extension View {
    func sheen(active: Bool = true) -> some View {
        modifier(Sheen(active: active))
    }
}

struct TabScreenHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The detail stays in the system face: a sentence set in the display face would read as a second title.
            Text(title)
                .font(DisplayFont.display(34))
                .tracking(-1.2)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// The tint arrives by inheritance from ``HostPickerView``'s tab view and cannot be exempted from above, so the menu sets its own ink.
    func menuInk() -> some View {
        tint(ColorPalette.ink)
    }

    /// `role: .destructive` colours the label but leaves the symbol to the tint, so a menu with ``menuInk()`` would show a red Delete with a white bin.
    func menuDanger() -> some View {
        tint(ColorPalette.danger)
    }

    func cardSurface() -> some View {
        self
            .padding(16)
            .cardBackground()
    }

    func cardBackground() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.20), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }

    func rowSurface() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.09), .white.opacity(0.045)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.07))
            }
    }

    /// The app's only iOS 26 API, called in one place so moving the floor is one edit. Glass samples what is behind it and Material does not, so the fallback adds ``ColorPalette/glassTint``. `interactive` is not reproducible below 26.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(ColorPalette.glassTint))
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
                    // Pinned inside the background, where the only thing it can reach is the
                    // material: on the view it would flip the *content's* colours as well.
                    .environment(\.colorScheme, .dark)
            }
        }
    }
}
