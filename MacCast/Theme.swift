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
    static let buttonHeight: CGFloat = 46
    /// The whole scroll wheel, chevrons and padding included. It is a nudge control, not a
    /// scrollbar: the two-finger gesture is still the fast way to move a long way.
    static let wheelHeight: CGFloat = 120
    /// A standalone key — the return beside the pointer. Bigger than a rail button because it is
    /// hit with a thumb already resting on the joystick rather than aimed at.
    static let quickKeySize: CGFloat = 60
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
}

/// The whole palette: two colours and a set of opacities.
///
/// No accent hue, deliberately. This screen is a frame around a picture, and the picture — a
/// Mac's desktop, whatever the user happens to be doing on it — is the only thing here entitled
/// to a colour. An accent would be competing with the content for attention, which is the one
/// thing chrome must never do. Where a state needs emphasis it gets brightness instead, which
/// is quieter and survives every accessibility setting a hue does not.
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
    /// A resting surface — rows, chips, anything that needs a little more body than the glass
    /// behind it.
    static let surface = Color.white.opacity(0.07)
    /// The frame around the picture, and the sheets that cover it. Near-black rather than black:
    /// a pure #000 next to a video's own blacks makes the picture look inset.
    static let backdrop = Color(red: 0.04, green: 0.04, blue: 0.045)

    /// How loudly to print a measurement. See `reading(_:)`.
    ///
    /// Brightness where an accent colour would have been a traffic light. A latency reading is
    /// information, not an alarm, and "worth a look" is exactly what a dimmer number says —
    /// whereas a red one shouts about something the user can do nothing about.
    static func reading(_ milliseconds: Double) -> Color {
        switch milliseconds {
        case ..<40: return ink.opacity(0.95)
        case ..<120: return ink.opacity(0.65)
        default: return ink.opacity(0.4)
        }
    }
}
