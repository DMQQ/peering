import SwiftUI

/// Every measurement the in-session chrome is built from.
///
/// One place, because "even" is only ever true by construction. The moment the rail and the
/// wheel each carry their own numbers they drift, and the drift is exactly what reads as sloppy:
/// a panel 20pt narrower than the one above it, a gap that is 6pt in one column and 10 in the
/// other.
enum ChromeMetrics {
    /// Every panel is this wide, so both columns line up top to bottom.
    ///
    /// Narrowed from 64 with the rail in mind — see ``railPadding``.
    static let panelWidth: CGFloat = 54
    /// Every panel corner, in every orientation.
    static let cornerRadius: CGFloat = 20
    /// The status pill's corner, collapsed and expanded.
    ///
    /// Two numbers rather than one shape, and neither of them is "capsule" — which is what this
    /// was, and what it could not stay. A capsule's corner is half its height, so a pill three
    /// rows tall grew a curve big enough to cut into the controls along its own top and bottom
    /// edges, and holding those clear would have meant padding the panel out to a shape it was
    /// no longer using.
    ///
    /// The pair is what makes the two states read as one object changing size: the collapsed
    /// pill is a stadium, and the expanded one keeps the softened look at a size that leaves its
    /// contents alone.
    ///
    /// Half the collapsed pill's height, which is what makes it a stadium rather than a rounded
    /// rectangle — and it has been that fraction of a different height twice since. It was 14
    /// when the pill was one 28-point line; when it grew to two lines the 14 stayed and read as a
    /// card that had not quite been squared off, and then the height grew again to give the two
    /// lines room. It follows the height now.
    static let pillCollapsedRadius: CGFloat = 30
    static let pillExpandedRadius: CGFloat = 26
    /// Inside a rail, above the first button and below the last — and the same as the gap either
    /// side of one, so the first button sits in its panel the way the ones below it sit between
    /// each other. An end gap larger than the side gaps is the shape that reads as a mistake
    /// without anyone being able to say why.
    ///
    /// Four is enough now that the buttons are circles — see ``ControlRail``. A stadium's ends
    /// curve inwards, and a square button needed a deep gap to stay inside that curve; a round one
    /// is narrowest exactly where the curve is, so it clears at almost any inset.
    static let railPadding: CGFloat = 4
    /// From a rail's edge to a button's, horizontally. The buttons are narrower than the rail by
    /// twice this, which is what keeps them inside the curve at the ends.
    static let railSidePadding: CGFloat = 4
    /// From the safe area to the first panel, on all three edges the chrome touches.
    static let edgeInset: CGFloat = 8
    /// From the home-indicator area to the bottom row. Larger than `edgeInset`, because the
    /// thumb holding the phone already rests across the bottom of the screen and the controls
    /// it has to reach past should not be underneath it.
    static let bottomInset: CGFloat = 22
    /// Between two stacked panels in one column.
    static let panelGap: CGFloat = 8
    /// Between two buttons inside one panel.
    static let buttonGap: CGFloat = 2
    /// Above the first and below the last item inside a panel.
    static let panelPadding: CGFloat = 5
    /// One rail button.
    ///
    /// Taller than it is wide, and that is a correction rather than a preference. At 46 the button
    /// was exactly square, and a square button in a capsule rail is a circle — which left an icon
    /// and its caption fighting for the same 46 points and the caption losing. The extra room goes
    /// to the label.
    static let buttonHeight: CGFloat = 62
    /// The whole scroll wheel, chevrons and padding included. It is a control for a thumb in the
    /// corner of the screen, not a scrollbar: a flick keeps the wheel turning, and the two-finger
    /// gesture is still the straight line to somewhere far away.
    static let wheelHeight: CGFloat = 120
    /// A standalone key — the return beside the pointer. Bigger than a rail button because it is
    /// hit with a thumb already resting on the joystick rather than aimed at.
    static let quickKeySize: CGFloat = 60

    /// How the portrait dock is divided: five columns, three rows when it is open.
    ///
    /// Structural rather than cosmetic, the pair of them. Every row shares the one column grid,
    /// which is what keeps row two's buttons under row one's and row three's under those — and
    /// five, rather than four, because row three is the five navigation keys and they land one
    /// per column with nothing left over. The chevron gets a column of its own rather than the
    /// narrow slot it used to have, for the same reason: a grid with one odd cell in it is a
    /// grid that only lines up in the rows that happen to have the odd cell.
    static let dockColumns = 5
    static let dockExpandedRows = 3

    /// How wide the dock's chevron is. Fixed, while the buttons beside it page.
    ///
    /// Narrower than a grid column, because it holds a glyph and no caption: it is the one control
    /// in the dock with nothing to aim at, so it is sized as a thumb target rather than as a cell.
    /// The columns give up the difference, which is why the dock's buttons are a little narrower
    /// than they were when the chevron held a column of its own.
    static let dockToggleWidth: CGFloat = 52

    /// How tall the dock's glass card stands, shut and open.
    ///
    /// **The card alone, and that is the correction.** The page dots used to be a row inside it,
    /// which made a dock standing at one row of buttons two rows thick. They are drawn under the
    /// card now, so the glass is exactly as thick as its buttons: 70 points shut rather than 82.
    ///
    /// Derived from the buttons rather than chosen, for the reason the rail heights already were:
    /// the number and the thing it has to contain cannot drift apart if there is only one of them.
    static let dockCollapsedHeight = buttonHeight + railPadding * 2

    /// The open dock's three rows of buttons.
    ///
    /// Split out because the pager is given exactly this much: a pager handed the whole card would
    /// take the padding with it and page its pages by the wrong amount.
    static let dockExpandedGridHeight = buttonHeight * CGFloat(dockExpandedRows)
        + buttonGap * CGFloat(dockExpandedRows - 1)

    static let dockExpandedHeight = dockExpandedGridHeight + railPadding * 2

    /// The strip the page dots sit in, drawn under the card rather than in it.
    ///
    /// Both states carry it. A shut dock pages as well, and the dots are the only thing on screen
    /// that says so: without them the swipe is invisible until somebody happens to try it, which
    /// is a control with one page as far as anybody can tell.
    static let dockPageDotsHeight: CGFloat = 10

    /// From the card's bottom edge to the dots under it.
    static let dockDotsGap: CGFloat = 6

    /// How tall the open dock stands altogether, card and dots together.
    ///
    /// What a panel above it has to stay clear of, and the reason it is not simply the card's
    /// height: a panel sized against the card would cover the dots, and they are how the current
    /// page is known rather than decoration.
    static let dockStandingHeight = dockExpandedHeight + dockDotsGap + dockPageDotsHeight

    /// The portrait dock's corner in each of its two states, on the same reasoning as the status
    /// pill's — see ``pillCollapsedRadius``. One row is a stadium; two rows keep a softened edge
    /// rather than growing a curve half the height of a panel four times as wide as it is tall.
    static let dockCollapsedRadius: CGFloat = dockCollapsedHeight / 2
    static let dockExpandedRadius: CGFloat = 28

    /// The share of the screen the portrait dock spans. Short of the full width on purpose: a bar
    /// running edge to edge would be the one piece of chrome here that was a different kind of
    /// object from the panels, which all float with a margin around them.
    static let dockWidthFraction: CGFloat = 0.9
}

/// How the chrome moves.
///
/// Two speeds, because there are two kinds of change and giving them the same timing is what
/// makes an interface feel mechanical: a thing that arrives on screen wants to be seen arriving,
/// and a thing reacting under a finger wants to have already reacted.
enum Motion {
    /// Panels, overlays, anything that appears or disappears. A spring rather than a curve — it
    /// settles into place instead of stopping, which is the difference between a panel that was
    /// pushed up and one that was switched on.
    static let settle = Animation.spring(response: 0.34, dampingFraction: 0.84)

    /// A control changing state. Shorter than `settle`, so the feedback lands with the tap
    /// rather than after it.
    static let tap = Animation.smooth(duration: 0.18)

    /// A screen arriving: the Connect header, the cards under it, a page of the tour.
    ///
    /// Critically damped, and it is the only spring here that is. `settle` and `morph` are allowed
    /// their give because both are moving a shape the user is already looking at — a panel
    /// appearing, a pill opening into a panel — and the overshoot is what says the thing has
    /// weight. An entrance is not that. It is a whole screen arriving in a dozen pieces, each on
    /// its own delay, and give in every one of them means the last frames disagree about which way
    /// is down: the header is still coming up while the first card is already settling, and the
    /// screen reads as restless rather than as arrived, however good any one piece looks.
    ///
    /// Long, for the same reason. Nothing here is answering a finger — it is the first thing the
    /// screen does, it does it once, and the distance travelled is large: the mark comes down from
    /// a centred display size to a header one. Cut it short and the movement becomes a jump.
    static let arrive = Animation.spring(response: 0.52, dampingFraction: 1)

    /// The Connect header's journey from the middle of the screen to its corner, in two halves.
    ///
    /// Two curves rather than one, and that is the whole of it: the leftward travel and the upward
    /// one are separate animations of separate values, so the mark does not take the diagonal.
    /// A straight line between two points is the one path that reads as a transition rather than
    /// as something moving — the header being the one thing on the screen the eye is given before
    /// anything else, it is worth the second curve.
    ///
    /// `travel` leads and `rise` follows, so the mark leaves the middle going left and climbs into
    /// its corner at the end of the movement rather than cutting across the screen. The split is
    /// well short of an L: both curves are still running for most of the journey, and the bow
    /// between them is what is left of the straight line.
    ///
    /// They have to share a duration. Two curves of different lengths are two arrivals, and the
    /// mark would land, move again, and land.
    static let travel = Animation.timingCurve(0.3, 0.6, 0.32, 1, duration: 0.88)
    static let rise = Animation.timingCurve(0.55, 0.12, 0.32, 1, duration: 0.88)

    /// The status pill opening into the status panel, and back.
    ///
    /// Its own speed, and slower than `settle`: nothing is arriving here — one shape is becoming
    /// a different one — and the travel is the whole of what there is to watch. Less damping than
    /// `settle` for the same reason, so the pill runs past its final size and comes back. That
    /// overshoot is the effect; a shape that stops dead at its new size reads as a swap however
    /// smooth the frames are.
    ///
    /// Damped where it is because the two sizes are far apart. At 0.78 the overshoot was there
    /// and *just* there — a frame or two of a shape already within a few points of its final one,
    /// which on a change this large is indistinguishable from having stopped. The give has to
    /// scale with the distance travelled, and this is the one animation in the app that travels
    /// a long way.
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.68)
}

/// The whole palette: a set of opacities, and the handful of colours that are states rather
/// than shades.
///
/// No accent hue by default, deliberately. This screen is a frame around a picture, and the
/// picture — a Mac's desktop, whatever the user happens to be doing on it — is the only thing
/// here entitled to a colour. An accent would be competing with the content for attention,
/// which is the one thing chrome must never do. Where a state needs emphasis it gets brightness
/// instead, which is quieter and survives every accessibility setting a hue does not.
///
/// The exceptions are the states white cannot say at arm's length: ``accent``, ``danger`` and
/// ``reading(_:)``.
enum ColorPalette {
    /// The ink. Selection, checkmarks, live indicators, anything that is "on".
    static let ink = Color.white
    /// Drawn on top of a filled `ink` surface.
    static let onInk = Color.black
    /// The one colour in the app.
    ///
    /// Everything else here is brightness, deliberately — this screen is a frame around a
    /// picture, and the picture is the only thing entitled to a hue. Selection is the case that
    /// needed more than brightness: white at 15% is a *shade*, not a state, and over a bright
    /// desktop at arm's length it is not a state at all. So the accent marks what is on, and
    /// nothing else uses it.
    ///
    /// System blue rather than a chosen colour, because it is already what every other control
    /// on the phone means by "this one is selected" and so needs no learning.
    static let accent = Color.blue

    /// A selected control's fill. Filled rather than tinted: the point of the accent is that a
    /// glance finds it, and a 25%-opacity blue on a dark panel is a glance that misses.
    static let selectedFill = Color.blue

    /// Something that did not work.
    ///
    /// One red for the whole app, so a failed terminal's tab and the line in its output that
    /// says why are the same red — two reds a few points apart is the kind of near-match that
    /// reads as a mistake without anyone being able to name it.
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.40)
    /// Something that may not have been meant, in a tool's own words. Dimmer than ``danger``,
    /// because a warning is a tool being careful and not a thing that has gone wrong.
    static let caution = Color(red: 0.97, green: 0.75, blue: 0.35)
    /// A resting surface — rows, chips, anything that needs a little more body than the glass
    /// behind it.
    static let surface = Color.white.opacity(0.07)
    /// The frame around the picture, and the sheets that cover it. Near-black rather than black:
    /// a pure #000 next to a video's own blacks makes the picture look inset.
    static let backdrop = Color(red: 0.04, green: 0.04, blue: 0.045)

    /// The wash under a frosted surface below iOS 26: what keeps the chrome the same object over a
    /// white document and over a black editor.
    ///
    /// **Heavy on purpose.** The material underneath it adapts to what is behind it, which is the
    /// one thing the chrome cannot do, because here the backdrop is a picture that can be anything.
    /// Over a blank document a thin frost lands within a few points of ``ink`` and the rail's
    /// nine-point captions stop reading, which is the failure ``accent`` is documented against. A
    /// wash this opaque closes that range, at the cost of letting the picture show through less.
    ///
    /// This is the single number to turn if the fallback reads wrong on a device. Everything else
    /// about it follows from the shapes the call sites already pass.
    static let glassTint = backdrop.opacity(0.70)

    /// How loudly to print a measurement. See `reading(_:)`.
    ///
    /// Brightness where an accent colour would have been a traffic light. A latency reading is
    /// information, not an alarm, and "worth a look" is exactly what a dimmer number says —
    /// whereas a red one shouts about something the user can do nothing about.
    static func reading(_ milliseconds: Double) -> Color {
        // Hue rather than brightness, and this is the one place in the app that breaks the
        // palette's own rule. The rule exists because a picture is the only thing here
        // entitled to a colour; a latency figure is a measurement, and the whole point of
        // showing it is to be noticed — three shades of white at arm's length are one shade.
        switch milliseconds {
        case ..<40: return .green
        case ..<120: return .yellow
        default: return .orange
        }
    }
}

/// The shared backdrop for every root tab: near-black with one soft light from above.
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            ColorPalette.backdrop
            RadialGradient(
                colors: [.white.opacity(0.07), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The one place the display face is named.
///
/// Reached for anything set as a *name* rather than as a label: the wordmark, a screen's title, the
/// headings of the tour. Named once because a face is a decision and not a value — four separate
/// `design: .serif` spellings are four chances for one of them to be left behind the day the app
/// picks a different face, and what that looks like is one heading in the app that is not like the
/// others, which is the sort of thing that reads as a mistake without anyone being able to say why.
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
/// `Text` cannot be resized the way a frame can. `.font()` is a discrete change — a name that
/// changes size jumps between the two sizes — so a label that resizes while everything around it
/// glides is the one part of a movement that does not move, however smoothly the rest of it goes.
/// That is what the Connect header's fold was: a mark travelling to its corner with a name
/// snapping under it, twice, at the size changes.
///
/// `Animatable` is the whole of the fix. The interpolated size arrives as a new value on every
/// frame of the animation and the label is re-rendered at it, so the name grows and shrinks with
/// the geometry rather than between two states of it. It costs a re-render per frame, which is
/// worth paying for the one label in the app whose size changes while it moves.
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

/// A row's subject: one glyph, in a rounded tile.
///
/// The Connect screen uses it for a device, the Sessions screen for a past connection, and the
/// settings rows use the same object at a third of the size (``Controls/icon(_:tint:)``) for a
/// switch's subject. One shape at two scales rather than two shapes that happen to look similar.
///
/// It lives here rather than as a method on whichever screen needed it first, because it *was* a
/// method on whichever screen needed it first — and the second screen copied the body out by hand
/// rather than reaching for it, which is how two copies of one surface style start drifting.
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

/// The wordmark: the app's name, with a light travelling across it.
///
/// Both screens that show the name (the introduction and the Connect header) show it with the
/// same light crossing it, which is the point: it is the one piece of the app that is a *sign*
/// rather than an interface, and a sign that behaves differently in two places is not one. The
/// light itself is ``Sheen``, which the tour's headings carry too.
struct Wordmark: View {
    let size: CGFloat
    let tracking: CGFloat

    var body: some View {
        Text("Peering")
            .modifier(AnimatableDisplay(size: size, tracking: tracking))
            .sheen()
    }
}

/// The light that crosses a name, as something more than one name can carry.
///
/// It was the wordmark's own body, and it moved out the day the tour's headings were given the same
/// treatment. A sweep that the second caller copies is two sweeps by the third, and a sign whose
/// light moves differently from the tour's is two effects that were meant to be one.
///
/// It is the one thing in this file that moves without being asked to, and it earns that by being
/// the only thing it is ever put on that is *not* an interface. A light crossing a name is how a
/// sign says it is lit; it says it without moving a letter, changing a colour, or making anyone
/// wait, which is more than any of the alternatives manage: letters that rise in sequence trade
/// legibility for a second, and a word that changes colour is asking to be looked at rather than
/// read.
private struct Sheen: ViewModifier {
    /// Whether the light is running, for a caller that keeps a screen alive without showing it. A
    /// page style `TabView` builds the page you are on and its neighbours, so a heading that did
    /// not ask would have three timelines running behind two pages nobody can see.
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the name is painted at, and it is the effect's number rather than a shade of choice.
    /// Light crossing light is nothing: a name already at the maximum leaves the sweep nowhere to
    /// go. At 78% the crossing reads as the light arriving and the name being left brighter for a
    /// moment, which is the whole of what a reflection off a wordmark is.
    ///
    /// Which is why this modifier paints as well as lights. The surface under the sweep is part of
    /// the effect, and a caller that set its own colour would get a sweep it could not see.
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
    /// **Why it is not `@State` on the modifier.** The modifier's storage survives being told to
    /// stop and start again, it is the same view throughout, so a heading whose page came back
    /// would resume wherever in the cycle the clock happened to be: a band appearing in the middle
    /// of the name and jumping to the edge a frame later. Inserted and removed with the overlay it
    /// belongs to, this one starts on the frame it appears.
    private struct Sweep<Mask: View>: View {
        @ViewBuilder var mask: () -> Mask

        /// When the light started, so the sweep begins on the frame the name does rather than
        /// wherever in an absolute cycle the clock happened to be.
        @State private var began = Date()

        /// One crossing, and the pause after it.
        private static var crossing: TimeInterval { 1.6 }
        private static var cycle: TimeInterval { 4.2 }

        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                // A timeline rather than a repeating animation, and it is not a preference. This
                // was `withAnimation(.linear(...).repeatForever)` kicked off from `onAppear`, and it
                // looked right for exactly as long as the header took to fold: the name's own size
                // changes at the end of the entrance, the animation on top of it is cancelled by the
                // re-layout that follows, and because the view's identity survives the change
                // `onAppear` never fires again. What was left was a sweep that had run once,
                // stopping off the side of the name where it could not be seen, indistinguishable
                // from an effect that never worked. A timeline has no transaction to be cancelled
                // by and reads the clock directly.
                TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                    band(width: width, height: height, elapsed: context.date.timeIntervalSince(began))
                }
                .mask { mask() }
            }
            .allowsHitTesting(false)
        }

        /// The light itself: a soft band, travelling left to right and then out of sight.
        private func band(width: CGFloat, height: CGFloat, elapsed: TimeInterval) -> some View {
            // Travelling from well off one side to well off the other, so that the crossing is the
            // first two fifths of a cycle that spends the rest of it beyond the last letter. The
            // pause at either end is what keeps this a detail rather than a strobe: a sweep that
            // restarts the moment it leaves is a loop, and a loop is a thing the eye starts waiting
            // for.
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
            // A band rather than a hard line: a gradient a third of the name wide, brightest in the
            // middle, is a reflection. The same thing at a tenth of the width is a scanning bar,
            // which reads as the app doing something rather than as the light falling on it, and
            // much wider than this and there is no edge to the light, only a name that gets
            // brighter.
            .frame(width: width * 0.34, height: height)
            .offset(x: (progress * 3 - 1.5) * width)
            .frame(width: width, height: height)
        }
    }
}

extension View {
    /// A light travelling across this name.
    ///
    /// For a name that is a *name*: the wordmark, a screen title, the headings of the tour. Not for
    /// a label: the sweep is what the eye is given on a surface that has nothing else to say, and
    /// a page where every line is doing it has no sign on it at all.
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
            // The display face, so a screen's title belongs to the same family as the wordmark that
            // opens the app and the headings inside the tour. The label under it stays in the system
            // face: one of these is the screen's name and the other is a sentence about it, and
            // setting both in the display face would make the tagline read as a second title.
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

/// A section heading: small, tracked, uppercase.
///
/// One voice for every label in the app rather than each screen choosing its own size. A headline
/// in one place and a caption in another is the kind of inconsistency nobody can name and everyone
/// can see.
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
    /// **A menu is not a control that is "on", so the accent has no business in one.** The palette
    /// gives the accent exactly one job, marking what is currently selected, and it does that on the
    /// controls the user is choosing between. Inside a menu that choice has already been made: the
    /// checkmark is a record of it rather than the choice itself, so a column of blue confirmations
    /// reads as a column of things that are live rather than a list of things that can be picked.
    ///
    /// The tint gets in by inheritance. ``HostPickerView`` puts the accent on the whole tab view,
    /// which is where the selected tab needs it, and a menu anywhere underneath takes it too. There
    /// is no way to exempt a subtree from above, so the menu has to say so itself, and this is that
    /// sentence in one place rather than in each of the eight menus.
    ///
    /// Destructive items are unaffected: ``role: .destructive`` colours its own row, and a red
    /// "Delete" stays red, which is the other half of what a menu item is allowed to be.
    func menuInk() -> some View {
        tint(ColorPalette.ink)
    }

    /// A destructive menu item, red in its words *and* in its icon.
    ///
    /// **`role: .destructive` is not enough on its own, and this is why it exists.** The role
    /// colours the label and leaves the symbol to the tint, so a menu carrying ``menuInk()`` gets a
    /// red "Delete" with a white bin beside it. A row whose two halves disagree about whether it is
    /// dangerous is worse than either answer on its own: the red says one thing, the white icon in
    /// front of it says another, and the reader has to decide which of them the app meant.
    ///
    /// Applied per item rather than by leaving destructive items out of ``menuInk()``, because the
    /// alternative is a row that silently depends on which tint happens to be reaching it, and that
    /// is the same defect as the blue icons were.
    func menuDanger() -> some View {
        tint(ColorPalette.danger)
    }

    /// A card, drawn on the backdrop rather than laid on top of it.
    ///
    /// The stroke is a gradient rather than one flat opacity: brighter along the top edge and
    /// fading down the sides is how a raised surface catches light, and it is the whole
    /// difference between a rectangle drawn on the background and a panel sitting in front of it.
    /// It costs nothing but a gradient, and no colour is added to do it.
    ///
    /// There is no fill, and taking it away was the fix rather than a tidy-up. It used to be
    /// ``ColorPalette/surface`` — white at 7% — and white at 7% over a near-black backdrop is not
    /// a raised surface, it is a grey one. Every card on every screen became the same flat grey
    /// panel, one shade lighter than the page it sat on and one shade darker than the rows inside
    /// it, so the three levels a card needs — page, card, row — collapsed into three greys a few
    /// points apart. That is the shape that reads as a mistake without anyone being able to name
    /// it. Outlined instead, the card keeps its edge from the stroke and its depth from the
    /// backdrop's own light, and the picture behind it is never covered up.
    func cardSurface() -> some View {
        self
            .padding(16)
            .cardBackground()
    }

    /// The card's shape alone, for a card built out of more than one block.
    ///
    /// The Connect screen's two halves — nearby, and the Macs already paired — are each padded
    /// around a divider that runs the full width of the card, and the single 16-point inset
    /// ``cardSurface()`` applies would pull that divider in to the padding instead of leaving it
    /// at the card's edge, which is what makes them two sections of one card rather than two cards
    /// with a gap between them.
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

    /// A row inside a card: the same trick one level down, and one step quieter, so a row reads
    /// as sitting on the card rather than cut into it.
    ///
    /// Shared rather than duplicated per screen — the home screen's cards and the source picker's
    /// rows are the same object seen twice, and two copies of a surface style drift apart at the
    /// first tweak.
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
    /// **This is the app's only iOS 26 API, and so it is the whole reason the floor was 26.**
    /// Panels, pills and buttons called `glassEffect` directly in twenty-five places, which turned
    /// a deployment target that should have been about APIs into one about a single modifier's
    /// appearance. Behind this, moving the floor is one build setting rather than twenty-five
    /// edits.
    ///
    /// The two branches are not the same material and do not pretend to be. Glass samples what is
    /// behind it and adapts to it; a `Material` blurs it and stays put. The fallback therefore
    /// carries ``ColorPalette/glassTint`` over the frost, because these panels sit on a picture
    /// that can be anything, and an unmodified frost over a white document turns a caption into a
    /// smudge. The hairline is the trick ``cardBackground()`` already uses: it is the difference
    /// between a rectangle drawn on the background and a panel sitting in front of it.
    ///
    /// What the fallback cannot reproduce is `interactive`. Glass takes the shape of the press and
    /// a material does not, so the eleven buttons that ask for it lose that below 26. The
    /// parameter stays explicit because the two are not interchangeable even on 26: the session
    /// status dot chooses plain deliberately, so that one press gets one answer rather than two.
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
                    // material. On the view it would flip the *content's* colours as well, which
                    // is a far larger change than making the frost predictable.
                    .environment(\.colorScheme, .dark)
            }
        }
    }
}

