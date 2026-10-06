import MacCastKit
import SwiftUI

/// Every measurement the in-session chrome is built from.
///
/// One place, because "even" is only ever true by construction: numbers carried at their call
/// sites drift, and the drift is what reads as sloppy.
enum ChromeMetrics {
    /// Every panel is this wide, so both columns line up top to bottom.
    static let panelWidth: CGFloat = 54
    /// Every panel corner, in every orientation.
    static let cornerRadius: CGFloat = 20
    /// The status pill's corner, collapsed and expanded.
    ///
    /// Two numbers rather than one shape, and neither is "capsule": a capsule's corner is half its
    /// height, so a pill three rows tall grew a curve that cut into the controls along its top and
    /// bottom edges. ``pillCollapsedRadius`` is half the collapsed pill's height, which is what
    /// makes it a stadium; the expanded one keeps the softened look at a size that leaves its
    /// contents alone.
    static let pillCollapsedRadius: CGFloat = 30
    static let pillExpandedRadius: CGFloat = 26
    /// The landscape status bar's widest, circles included. See ``RemoteScreen/statusBarWidthCap(in:)``.
    static let statusBarMaxWidth: CGFloat = 460
    /// Inside a rail, above the first button and below the last, and equal to the gap between two
    /// of them, so the ends read like the sides. Four is enough because the buttons are circles,
    /// narrowest exactly where a stadium rail's ends curve inwards.
    static let railPadding: CGFloat = 4
    /// From a rail's edge to a button's, horizontally. Buttons are narrower than the rail by twice
    /// this, which keeps them inside the curve at the ends.
    static let railSidePadding: CGFloat = 4
    /// From the safe area to the first panel, on all three edges the chrome touches.
    static let edgeInset: CGFloat = 8
    /// From the home-indicator area to the bottom row. Larger than `edgeInset`, because the thumb
    /// already rests across the bottom of the screen.
    static let bottomInset: CGFloat = 22
    /// Between two stacked panels in one column.
    static let panelGap: CGFloat = 8
    /// How much of the screen the picture keeps to itself, each side, in landscape, so a mosaic
    /// drawn to the screen's own edges does not run under the rails.
    ///
    /// Applied to the *bounds* the picture is laid out in, not to the video alone: every rectangle
    /// that lands on a window (the tiles, the cursor, a tap, the zoom a tap travels with) is the
    /// letterboxed rect moved by the canvas's transform, and all of them are measured against the
    /// rectangle the pixels are actually drawn in.
    static let pictureInset: CGFloat = 0.125
    /// Between two buttons inside one panel.
    static let buttonGap: CGFloat = 2
    /// Above the first and below the last item inside a panel.
    static let panelPadding: CGFloat = 5
    /// One rail button. Taller than it is wide: square left the icon and its caption fighting for
    /// the same height, and the caption lost.
    static let buttonHeight: CGFloat = 62
    /// The whole scroll wheel, chevrons and padding included. A control for a thumb in the corner
    /// of the screen, not a scrollbar: a flick keeps the wheel turning.
    static let wheelHeight: CGFloat = 120
    /// A standalone key: the return beside the pointer. Bigger than a rail button because it is hit
    /// with a thumb already resting on the joystick rather than aimed at.
    static let quickKeySize: CGFloat = 60

    /// How the portrait dock is divided: five columns, three rows when it is open.
    ///
    /// Structural rather than cosmetic: every row shares the one column grid, so each row's buttons
    /// land under the one above. Five rather than four, because row three is the five navigation
    /// keys, one per column with nothing left over.
    static let dockColumns = 5
    static let dockExpandedRows = 3

    /// How wide the dock's chevron is. Fixed, while the buttons beside it page.
    ///
    /// Narrower than a grid column: it holds a glyph and no caption, so it is sized as a thumb
    /// target rather than as a cell, and the columns give up the difference.
    static let dockToggleWidth: CGFloat = 52

    /// How tall the dock's glass card stands, shut and open. The card alone: the page dots are
    /// drawn under it.
    ///
    /// Derived from the buttons rather than chosen, so the number and the thing it has to contain
    /// cannot drift apart.
    static let dockCollapsedHeight = buttonHeight + railPadding * 2

    /// The open dock's three rows of buttons.
    ///
    /// Split out because the pager is given exactly this much: handed the whole card it would take
    /// the padding with it and page by the wrong amount.
    static let dockExpandedGridHeight = buttonHeight * CGFloat(dockExpandedRows)
        + buttonGap * CGFloat(dockExpandedRows - 1)

    static let dockExpandedHeight = dockExpandedGridHeight + railPadding * 2

    /// The strip the page dots sit in, drawn under the card rather than in it, in both states. The
    /// dots are the only thing on screen that says a shut dock pages.
    static let dockPageDotsHeight: CGFloat = 10

    /// From the card's bottom edge to the dots under it.
    static let dockDotsGap: CGFloat = 6

    /// How tall the open dock stands altogether, card and dots together.
    ///
    /// What a panel above it has to stay clear of: sized against the card alone, a panel would
    /// cover the dots.
    static let dockStandingHeight = dockExpandedHeight + dockDotsGap + dockPageDotsHeight

    /// The portrait dock's corner in each of its two states, on the same reasoning as
    /// ``pillCollapsedRadius``: one row is a stadium, two rows keep a softened edge.
    static let dockCollapsedRadius: CGFloat = dockCollapsedHeight / 2
    static let dockExpandedRadius: CGFloat = 28

    /// The share of the screen the portrait dock spans. Short of the full width, so it floats with
    /// a margin like every panel rather than running edge to edge.
    static let dockWidthFraction: CGFloat = 0.9
}

/// How the chrome moves. Two speeds, because a thing that arrives wants to be seen arriving and a
/// thing reacting under a finger wants to have already reacted.
enum Motion {
    /// The spring behind ``settle``, as two numbers rather than as an `Animation`.
    ///
    /// One thing in this app has to *evaluate* this curve rather than hand it to SwiftUI: the
    /// picture's zoom and pan reach the screen as a `UIView` layer transform written frame by frame
    /// (see ``VideoLayerView/updateUIView(_:context:)``), so there is no SwiftUI value for
    /// `withAnimation` to interpolate. See ``settleProgress(at:)``.
    static let settleResponse: Double = 0.34
    static let settleDamping: Double = 0.84

    /// The picture moving between an arrangement and one of its tiles. Quicker than ``settle``,
    /// because this is a movement the user asked for by name and is waiting on.
    static let pictureResponse: Double = 0.24

    /// Panels, overlays, anything that appears or disappears. A spring rather than a curve: it
    /// settles into place instead of stopping.
    static let settle = Animation.spring(response: settleResponse, dampingFraction: settleDamping)

    /// Where ``settle`` has got to `time` seconds in, from 0 to just over 1.
    ///
    /// The spring's own solution, not a curve that looks like it, so a movement that cannot go
    /// through the animation system is the same movement rather than a different one wearing the
    /// name. It passes 1 and comes back, which is the give. Damping of 1 or more is treated as 1:
    /// the critically damped branch, where the give stops.
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

    /// A control changing state. Shorter than `settle`, so the feedback lands with the tap.
    static let tap = Animation.smooth(duration: 0.18)

    /// A screen arriving: the Connect header, the cards under it, a page of the tour.
    ///
    /// Critically damped, and the only spring here that is: a whole screen arrives in a dozen
    /// pieces on their own delays, and give in each one leaves the last frames disagreeing about
    /// which way is down. Long for the same reason, since nothing here is answering a finger and
    /// the distance travelled is large.
    static let arrive = Animation.spring(response: 0.52, dampingFraction: 1)

    /// The Connect header's journey from the middle of the screen to its corner, in two halves.
    ///
    /// Two curves rather than one, so the mark does not take the diagonal: `travel` leads and
    /// `rise` follows, and both are still running for most of the journey. They have to share a
    /// duration, or the mark lands, moves again and lands.
    static let travel = Animation.timingCurve(0.3, 0.6, 0.32, 1, duration: 0.88)
    static let rise = Animation.timingCurve(0.55, 0.12, 0.32, 1, duration: 0.88)

    /// The status pill opening into the status panel, and back.
    ///
    /// Slower than `settle` and less damped: one shape is becoming a different one, and the
    /// overshoot past its final size is the effect. The give has to scale with the distance
    /// travelled, and this is the one animation in the app that travels a long way.
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.68)
}

/// The whole palette: a set of opacities, and the handful of colours that are states rather
/// than shades.
///
/// No accent hue by default: the picture is the only thing here entitled to a colour. The
/// exceptions are the states white cannot say at arm's length: ``accent``, ``danger`` and
/// ``reading(_:)``.
enum ColorPalette {
    /// The ink. Selection, checkmarks, live indicators, anything that is "on".
    static let ink = Color.white
    /// Drawn on top of a filled `ink` surface.
    static let onInk = Color.black
    /// The one colour in the app. It marks what is on and nothing else uses it: white at 15% over a
    /// bright desktop is a shade, not a state.
    ///
    /// System blue rather than a chosen colour, because it is already what every other control on
    /// the phone means by "this one is selected".
    static let accent = Color.blue

    /// A selected control's fill. Filled rather than tinted: a 25%-opacity blue on a dark panel is
    /// a glance that misses.
    static let selectedFill = Color.blue

    /// The flash under a finger, drawn over a control's state fill. A fade alone cannot show a
    /// press over video: dimming a white glyph reads as the control switching off.
    static let pressedFill = Color.white.opacity(0.22)

    /// Something that did not work. One red for the whole app, so a failed terminal's tab and the
    /// line in its output that says why are the same red.
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.40)
    /// Something that may not have been meant, in a tool's own words. Dimmer than ``danger``: a
    /// warning is not a thing that has gone wrong.
    static let caution = Color(red: 0.97, green: 0.75, blue: 0.35)
    /// A resting surface: rows, chips, anything that needs a little more body than the glass
    /// behind it.
    static let surface = Color.white.opacity(0.07)
    /// The frame around the picture, and the sheets that cover it. Near-black rather than black:
    /// a pure #000 next to a video's own blacks makes the picture look inset.
    static let backdrop = Color(red: 0.04, green: 0.04, blue: 0.045)

    /// The wash under a frosted surface below iOS 26: what keeps the chrome the same object over a
    /// white document and over a black editor.
    ///
    /// Heavy on purpose. The material adapts to what is behind it, and here the backdrop is a
    /// picture that can be anything: over a blank document a thin frost lands within a few points
    /// of ``ink`` and the rail's captions stop reading. This is the single number to turn if the
    /// fallback reads wrong on a device.
    static let glassTint = backdrop.opacity(0.70)

    /// How loudly to print a measurement. See `reading(_:)`.
    ///
    /// Brightness where an accent colour would have been a traffic light: a latency reading is
    /// information, not an alarm, and a dimmer number is what "worth a look" looks like.
    static func reading(_ milliseconds: Double) -> Color {
        // Hue rather than brightness, the one place in the app that breaks the palette's own
        // rule: a latency figure is a measurement, and three shades of white at arm's length
        // are one shade.
        //
        // The bands live in ``LatencyQuality``, which also decides the word the collapsed pill
        // uses: one set of thresholds, or the pill says "Slow" in green.
        switch LatencyQuality.of(milliseconds: milliseconds) {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        }
    }
}

/// One soft light from the top. A single flat near-black reads as a hole rather than as a surface;
/// this gives it a direction without adding a colour, which the palette does not have to spare.
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

/// The shared backdrop for every root tab: near-black with one soft light from above.
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

/// The one place the display face is named, so a change of face is one edit: four separate
/// `design: .serif` spellings are four chances for one heading to be left behind.
///
/// Reached for anything set as a *name* rather than as a label: the wordmark, a screen's title, the
/// headings of the tour.
enum DisplayFont {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }

    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, design: .serif).weight(.bold)
    }
}

/// The display face, at a size an animation can interpolate.
///
/// `.font()` is a discrete change, so a label that resizes while everything around it glides is the
/// one part of a movement that does not move. `Animatable` re-renders the label at each frame's
/// size, which costs a re-render per frame.
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

/// A row's subject: one glyph, in a rounded tile. One shape at two scales, with
/// ``Controls/icon(_:tint:)`` the same object at a third of the size.
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

/// The wordmark: the app's name, with a light travelling across it. The light is ``Sheen``, which
/// the tour's headings carry too.
struct Wordmark: View {
    let size: CGFloat
    let tracking: CGFloat

    var body: some View {
        Text("Peering")
            .modifier(AnimatableDisplay(size: size, tracking: tracking))
            .sheen()
    }
}

/// The light that crosses a name, as something more than one name can carry: the one thing in this
/// file that moves without being asked to, because it is only ever put on a sign rather than an
/// interface.
private struct Sheen: ViewModifier {
    /// Whether the light is running, for a caller that keeps a screen alive without showing it. A
    /// page-style `TabView` builds the page you are on and its neighbours, so without this a
    /// heading would run three timelines behind two pages nobody can see.
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the name is painted at. Light crossing light is nothing, so this modifier paints as
    /// well as lights, and a caller that set its own colour would get a sweep it could not see.
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

    /// The light itself, drawn in a view of its own so that the clock starts when the light does.
    ///
    /// It is not `@State` on the modifier: that storage survives being told to stop and start
    /// again, so a page coming back would resume wherever in the cycle the clock was, with a band
    /// appearing in the middle of the name. Inserted and removed with the overlay it belongs to,
    /// this one starts on the frame it appears.
    private struct Sweep<Mask: View>: View {
        @ViewBuilder var mask: () -> Mask

        /// When the light started: the sweep begins on the frame the name does, not wherever in an
        /// absolute cycle the clock happened to be.
        @State private var began = Date()

        /// One crossing, and the pause after it.
        private static var crossing: TimeInterval { 1.6 }
        private static var cycle: TimeInterval { 4.2 }

        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                // A timeline rather than `repeatForever` from `onAppear`: a re-layout cancels the
                // repeat animation, the view's identity survives the change so `onAppear` never
                // fires again, and what is left is a sweep that ran once and stopped off the side
                // of the name. A timeline has no transaction to be cancelled by.
                TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                    band(width: width, height: height, elapsed: context.date.timeIntervalSince(began))
                }
                .mask { mask() }
            }
            .allowsHitTesting(false)
        }

        /// The light itself: a soft band, travelling left to right and then out of sight.
        private func band(width: CGFloat, height: CGFloat, elapsed: TimeInterval) -> some View {
            // Travelling well off one side to well off the other: the crossing is the first two
            // fifths of a cycle that spends the rest beyond the last letter, so the light pauses
            // at either end rather than looping.
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
            // A band a third of the name wide, brightest in the middle: narrower reads as a
            // scanning bar, and much wider and there is no edge to the light, only a brighter name.
            .frame(width: width * 0.34, height: height)
            .offset(x: (progress * 3 - 1.5) * width)
            .frame(width: width, height: height)
        }
    }
}

extension View {
    /// A light travelling across this name.
    ///
    /// For a name that is a *name*: the wordmark, a screen title, a heading of the tour. Not for a
    /// label: a page where every line is doing it has no sign on it at all.
    func sheen(active: Bool = true) -> some View {
        modifier(Sheen(active: active))
    }
}

/// A reliable tab heading that does not disappear with navigation-bar scroll state.
struct TabScreenHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The display face, so a title belongs to the same family as the wordmark and the tour's
            // headings. The detail stays in the system face: a sentence about the name set in the
            // display face would read as a second title.
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

/// A section heading: small, tracked, uppercase. One voice for every label in the app rather than
/// each screen choosing its own size.
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
    /// Menu items, drawn in the app's ink rather than in whatever tint reached them.
    ///
    /// The tint arrives by inheritance, from ``HostPickerView``'s tab view, and there is no way to
    /// exempt a subtree from above, so the menu says so itself. A menu is not a control that is
    /// "on": the checkmark records a choice already made. Destructive items are unaffected, since
    /// ``role: .destructive`` colours its own row.
    func menuInk() -> some View {
        tint(ColorPalette.ink)
    }

    /// A destructive menu item, red in its words *and* in its icon.
    ///
    /// `role: .destructive` colours the label and leaves the symbol to the tint, so a menu carrying
    /// ``menuInk()`` would get a red "Delete" with a white bin beside it. Applied per item, rather
    /// than by leaving destructive items out of ``menuInk()`` and letting the tint reach them.
    func menuDanger() -> some View {
        tint(ColorPalette.danger)
    }

    /// A card, drawn on the backdrop rather than laid on top of it.
    ///
    /// The stroke is a gradient, brighter along the top edge and fading down the sides, which is
    /// what makes a panel sit in front of the background rather than be drawn on it. There is no
    /// fill: a translucent white fill collapses page, card and row into three greys a few points
    /// apart.
    func cardSurface() -> some View {
        self
            .padding(16)
            .cardBackground()
    }

    /// The card's shape alone, for a card built out of more than one block.
    ///
    /// The Connect screen's two halves are each padded around a divider running the full width of
    /// the card, which ``cardSurface()``'s single 16-point inset would pull in to the padding.
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

    /// A row inside a card: the same trick one level down and one step quieter, so a row reads as
    /// sitting on the card rather than cut into it.
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

    /// The chrome that floats over the picture: Liquid Glass on iOS 26, a tinted frost before it.
    ///
    /// The app's only iOS 26 API, and so the reason the floor is 26: called directly in twenty-five
    /// places, moving the floor would be twenty-five edits rather than one build setting. Glass
    /// samples what is behind it and a `Material` does not, so the fallback carries
    /// ``ColorPalette/glassTint`` over the frost. `interactive` is not reproducible below 26, and
    /// stays explicit because the session status dot chooses plain deliberately.
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

