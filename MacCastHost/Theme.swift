import SwiftUI

/// The host's palette, in the same world as the client's.
///
/// These were semantic once — `Color.primary`, `.windowBackgroundColor`, `.regularMaterial` —
/// and the argument for that was that this is a Mac app living in a window that may be in either
/// appearance. The argument was wrong, and the reason it was wrong is worth keeping: a semantic
/// palette inherits from the *system*, so the window came out as stock macOS grey with the frost
/// of a settings panel, the user's own accent sprayed across every sidebar glyph, and the fully
/// saturated system green and red for state. The phone, sitting next to it on the desk, was near
/// black with one blue in it. Two apps that are meant to read as one product were reading as a
/// product and a system utility.
///
/// So the values are literal now, and the window is dark by fiat rather than by preference — see
/// `MacCastHostApp`, which pins the appearance. A host window that followed a light Mac into a
/// white palette would be the same mistake again, one appearance later.
///
/// Two copies of these constants, because sharing them would mean moving them into `RemoteCore`
/// — the wire protocol — and a UI dependency there would outlive any benefit from saving them.
enum HostPalette {
    // MARK: Stage

    /// Everything sits on this. Near-black rather than black, and the phone's own value exactly:
    /// a pure #000 next to the video's blacks makes the picture look inset in its own window.
    static let backdrop = Color(red: 0.04, green: 0.04, blue: 0.045)

    /// A panel resting on the stage.
    ///
    /// A flat wash rather than a material. The frost was doing two jobs — depth and adaptation —
    /// and on a stage this dark it only did the second, by lifting every surface to the grey of
    /// the window behind it. Depth comes from the lit edge instead, which is a thing that can be
    /// drawn on purpose rather than a thing the system decides.
    static let surface = Color.white.opacity(0.045)
    /// A row, tile or hover inside a panel. Twice the panel's own lift, so the two never read
    /// as the same surface at two sizes.
    static let raised = Color.white.opacity(0.085)

    /// The stage's own light: a touch brighter at the top, gone by a third of the way down.
    ///
    /// Hue-free, which is the whole difference from what it replaces. This used to be the accent
    /// at 4.5% washed from the top-left with a radial accent behind the corner, and two accent
    /// washes in one window is how a dark app still reads as blue. Light from above says where
    /// the window is lit; colour says nothing at all.
    static let stageLight = LinearGradient(
        colors: [Color.white.opacity(0.035), .clear],
        startPoint: .top,
        endPoint: .center
    )

    // MARK: Ink

    /// The ink: selection, a live session, anything that is on.
    static let ink = Color.white
    /// Muted ink: a state that is neither good nor bad, and the resting tone for labels.
    static let muted = Color.white.opacity(0.62)
    /// The quietest tone that still reads: idle, absent, switched off.
    ///
    /// Held at 4.6:1 against the stage rather than taken down to where it looks right, because
    /// this is what a timestamp and an inactive glyph are drawn in and "quiet" is not a licence
    /// to be unreadable. Anything quieter belongs in `muted`.
    static let faint = Color.white.opacity(0.46)

    // MARK: Edges

    /// Hairline for a divider or a row that needs an edge but no lift.
    static let hairline = Color.white.opacity(0.08)
    /// The lit edge of a raised surface.
    ///
    /// A gradient rather than one flat opacity: brighter along the top edge and fading down the
    /// sides is how a surface catches light from above, and it is the whole difference between a
    /// rectangle drawn on the background and a panel sitting in front of it. Costs a gradient and
    /// adds no colour.
    static let litEdge = LinearGradient(
        colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// What the system-drawn controls are tinted with, and a trap worth writing down.
    ///
    /// It has to be `Color.primary`, not `HostPalette.ink`. Both are white on this window and only
    /// one of them works: a tint of `.primary` leaves buttons and segmented controls in the
    /// neutral grey macOS draws when it has been given no colour to work with, and a tint of a
    /// literal `Color.white` paints every bordered button and every selected segment as a solid
    /// white pill — `Forget all` and `Copy all` and three pickers all arriving as the brightest
    /// thing on a near-black stage, which is the whole problem this palette exists to solve.
    static let controlTint = Color.primary

    // MARK: State

    /// The one colour in the app.
    ///
    /// Fixed rather than the system accent, so both apps mark "this one is on" with the same
    /// blue whatever the user has told macOS their highlight colour is — and so a Mac set to a
    /// warm accent does not tint a window whose entire subject is the picture inside it.
    static let accent = Color.blue

    /// State colours are reserved for operational feedback, never decoration.
    ///
    /// Tuned down from the system tones on purpose. `systemGreen` and `systemRed` are mixed to
    /// survive a grey background; on this one they are the loudest thing in the window, and a
    /// dot that shouts louder than a failure's own sentence is a dot with the wrong job.
    static let success = Color(red: 0.36, green: 0.85, blue: 0.55)
    static let caution = Color(red: 0.97, green: 0.71, blue: 0.30)
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.40)

    // MARK: Measure

    /// Panels, and the one radius the window is built from. Large enough to read as a deliberate
    /// shape rather than a rounded rectangle, small enough that a 245-point picture still fits
    /// inside one without the corners eating it.
    static let panelRadius: CGFloat = 18
    /// A control: buttons, pills, the icon chips.
    static let controlRadius: CGFloat = 10
}

/// The one place the display face is named on this side of the wire.
///
/// The client has the same enum in its own `Theme.swift`, and the two are copies for the same
/// reason `HostPalette` above is: a face is a decision and not a value. The wordmark in the
/// sidebar, the one in About, a screen's title and every section heading are four spellings of it,
/// and four spellings are four chances for one to be left behind the day the face changes — which
/// is how an app ends up with one heading that is not like the others, the sort of thing that
/// reads as a mistake without anyone being able to say why.
///
/// Serif rather than the system face, and serif is the whole of the effect: the phone sets its
/// wordmark, its screen titles and the tour's headings in it, and two windows meant to read as one
/// product do not get to disagree about which family their names are set in.
///
/// Bold at every size, which is the client's rule too — the face is used for names, and a name set
/// as a label is the one thing this is for.
enum HostDisplayFont {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }
}

enum HostMotion {
    static let hover = Animation.spring(response: 0.24, dampingFraction: 0.86)
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.78)
    static let state = Animation.spring(response: 0.36, dampingFraction: 0.88)
}

extension View {
    /// Small explanatory text under a control: muted, and allowed to take the lines it needs.
    func hostCaption(_ color: Color = HostPalette.muted) -> some View {
        font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The window's switch: small, in the accent.
    func hostSwitch() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(HostPalette.accent)
    }

    /// A panel: a wash on the stage, lit along its top edge, with the shadow of something sitting
    /// a few points above it rather than pasted onto it.
    func hostPanel(cornerRadius: CGFloat = HostPalette.panelRadius) -> some View {
        background(HostPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(HostPalette.litEdge, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.34), radius: 16, y: 7)
    }

    /// The live stream's frame: the one object in the window that is not a panel.
    ///
    /// A double bezel rather than a single stroke — a crisp inner edge around the picture and a
    /// softer rim outside it — because this is the instrument the window exists to show, and the
    /// one place worth spending a second edge on. The shadow is deeper than a panel's and carries
    /// a real offset: this is the thing nearest the viewer.
    func hostPrimaryPanel(cornerRadius: CGFloat = HostPalette.panelRadius) -> some View {
        padding(3)
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .strokeBorder(HostPalette.litEdge, lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(HostPalette.hairline, lineWidth: 1)
                    .padding(3)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
    }
}

/// The window's primary action, and the only control that gets a fill of its own.
///
/// The two states are deliberately not equals, and they are not two versions of one button
/// either. Hosting is a solid accent — the thing to press, the only filled control anywhere in
/// this window. Stopping is an outline: a filled slab of the same size says the same thing about
/// both, and a bright button waiting to end a session is an invitation to end a session. The way
/// out should be visible and quiet, and it should light up when the pointer reaches it.
struct HostHostingButtonStyle: ButtonStyle {
    let isHosting: Bool

    func makeBody(configuration: Configuration) -> some View {
        HostingButtonBody(isHosting: isHosting, configuration: configuration)
    }

    /// A view rather than a modifier chain, because the outline needs to know the pointer is on
    /// it and a `ButtonStyle` has nowhere to keep that.
    ///
    /// Named anything but `Body`: a nested type called `Body` satisfies `ButtonStyle`'s own
    /// associated type, and the conformance then fails asking for a `Body` that is a `View`.
    private struct HostingButtonBody: View {
        let isHosting: Bool
        let configuration: Configuration

        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHosting ? HostPalette.ink : .white)
                .background(
                    isHosting
                        ? (hovering ? HostPalette.raised : Color.clear)
                        : HostPalette.accent,
                    in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                        .strokeBorder(
                            isHosting
                                ? AnyShapeStyle(HostPalette.litEdge)
                                : AnyShapeStyle(Color.white.opacity(0.22)),
                            lineWidth: 1
                        )
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .shadow(
                    color: isHosting ? .clear : HostPalette.accent.opacity(configuration.isPressed ? 0.12 : 0.28),
                    radius: configuration.isPressed ? 3 : 10,
                    y: configuration.isPressed ? 1 : 5
                )
                .animation(HostMotion.press, value: configuration.isPressed)
                .animation(HostMotion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
