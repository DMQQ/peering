import Foundation

/// What a notch of the wheel is worth, in the two units that have to agree.
///
/// The wheel is a *notched* control, and that is the whole of the redesign. A mouse wheel does not
/// report how far a finger moved; it reports whole detents, and a detent is a fixed amount of
/// document. Everything here is one of those fixed amounts.
///
/// - ``travel`` is how far a finger moves to earn one notch.
/// - ``pixelsPerPoint`` is this screen's one scale from a finger's travel to the Mac's content.
///   Shared deliberately: the two-finger drag on the picture already moved content at two pixels
///   to the point, and the wheel now agrees with it, so two controls cannot disagree about what a
///   centimetre of thumb is worth. The wheel used to have a scale of its own — six pixels to the
///   point, three times this — and a scale nobody else used is half of what "imprecise" meant: a
///   thumb's smallest deliberate movement is a point or two, which at six times was twelve pixels
///   of document, too coarse to land on a line and too small to feel as a step.
/// - ``pixels`` is their product, in the unit the host's wheel event is built in (`units: .pixel`).
///   Derived rather than written down, so the three cannot drift apart.
///
/// Twenty-four pixels is about a line of text — a line of a document is twenty-odd points, a row
/// of a terminal fifteen — and that is the reason for the number: one notch is one line, the
/// smallest amount of scrolling that means anything on a desktop and the largest that is still a
/// *small* amount.
public enum ScrollNotch {
    /// Points of finger travel for one notch.
    ///
    /// Twelve: about a thumb tip's width, and a tenth of the panel. Far enough to be a movement
    /// the hand made on purpose rather than a tremor, close enough that the notch arrives while
    /// the wheel is still being rolled rather than after it has been let go.
    public static let travel: Double = 12

    /// Pixels of the Mac's content for a point of finger travel.
    ///
    /// Two rather than one, which is where the two-finger drag started: at one, a point of finger
    /// travel moves a single pixel and scrolling a page takes several swipes. The wheel borrows
    /// the figure rather than keeping one of its own; a second scale is what it had before.
    public static let pixelsPerPoint: Double = 2

    /// Pixels of the Mac's content for one notch — what the host is told to scroll.
    public static var pixels: Double { travel * pixelsPerPoint }
}

/// The wheel's own state: how far it has turned, and how much of that has been sent.
///
/// A type rather than a pair of `@State` properties in the view, because this arithmetic is the
/// whole of what makes the control precise — travel in, whole notches out, with the part of a
/// notch that is not one yet carried over to the next sample — and it is the one part of the wheel
/// that can be checked without a phone in a hand. `MacCastTests` does.
public struct ScrollWheelState {
    /// Travel that has not earned a notch yet, in points.
    ///
    /// The one piece of state here, and it is kept in points rather than in notches on purpose.
    /// Dividing each sample by the notch and adding the fractions loses travel to rounding at
    /// exactly the moment it matters: eleven points and then one point is not twelve points in
    /// binary floating point, and a wheel that had been pushed a whole notch would sit a ten-
    /// billionth of a point short of delivering it. Subtracting whole notches from the travel
    /// itself cannot do that — eleven and one are both exact, and their sum is twelve.
    ///
    /// Always within one notch of zero in either direction, because ``roll(points:)`` settles it.
    private var carry: Double = 0

    /// Notches already handed over, so that the same one is not counted twice.
    public private(set) var delivered: Int = 0

    /// A wheel at rest, in a detent. The synthesized memberwise init would be internal, and the
    /// view that owns one is in the app rather than here.
    public init() {}

    /// How far the wheel has turned, in notches, for the rim to draw.
    ///
    /// Continuous, so the rim turns smoothly under the finger: a wheel that has turned half a
    /// notch is half a notch along and is drawn there. The Mac is never sent the half — and this
    /// being *derived* rather than tracked is what guarantees that, because there is no second
    /// number here that could disagree with the first about where the wheel is.
    public var phase: Double { Double(delivered) + carry / ScrollNotch.travel }

    /// Turns the wheel by a finger's travel, in points, and returns the whole notches that earned.
    ///
    /// Usually zero. Most samples of a drag are part of the notch being rolled rather than a notch
    /// of their own, which is exactly the difference between this and the slider: that one sent
    /// every sample it was given, so the amount scrolled was however far the hand happened to go.
    public mutating func roll(points: Double) -> Int {
        carry += points
        var whole = 0
        // Loops rather than a division, because a sample can be worth several notches — a fast
        // flick covers thirty points between two frames — and because subtracting the notch is
        // exact where dividing by it is not.
        while carry >= ScrollNotch.travel {
            carry -= ScrollNotch.travel
            whole += 1
        }
        while carry <= -ScrollNotch.travel {
            carry += ScrollNotch.travel
            whole -= 1
        }
        guard whole != 0 else { return 0 }
        delivered += whole
        return whole
    }

    /// Turns the wheel by whole notches, or by the fraction of one a coasting wheel covered in an
    /// interval.
    public mutating func roll(notches: Double) -> Int {
        roll(points: notches * ScrollNotch.travel)
    }

    /// Seats the wheel in the nearest notch, returning the whole notches that moves it by.
    ///
    /// The detent spring. A wheel at rest is always *in* a detent — the spring in a real one sees
    /// to that, pulling it back if it was pushed less than halfway and forward if it was pushed
    /// more — and this is that spring, run when the finger leaves. It costs at most half a notch
    /// of scroll, in either direction, and it buys the thing the whole control depends on: after
    /// every gesture the wheel is a whole number of notches from where it started, so the arrows
    /// above and below always deliver exactly one, and can never be swallowed by a wheel that
    /// happened to be resting between notches.
    public mutating func seat() -> Int {
        let half = ScrollNotch.travel / 2
        let whole = carry > half ? delivered + 1 : (carry < -half ? delivered - 1 : delivered)
        carry = 0
        let moved = whole - delivered
        delivered = whole
        return moved
    }
}

/// What a wheel does after the finger lets go of it.
///
/// A wheel that has been spun keeps turning, and this is the shape of that: a rate that decays
/// exponentially, so a flick covers distance and then comes to rest. The two alternatives are both
/// wrong for this control. Stopping dead is what the slider did, and it is why a thumb-sized
/// control could not move a long way. Running on is a document that has gone somewhere nobody sent
/// it — which is why the decay is calibrated rather than merely slowed, and why a touch on the
/// wheel catches it.
public enum WheelSpin {
    /// The fastest a flick can launch the wheel, in notches per second.
    ///
    /// A phone flick is a violent thing — a thousand points a second is ordinary, and at twelve
    /// points to a notch that is eighty notches a second — so the cap is for the flick that is not
    /// ordinary. Without it the first fifth of a second would carry a whole document past the
    /// user. At the cap the wheel turns two notches a frame, which is as much as the eye follows.
    public static let launchLimit: Double = 120

    /// Seconds for the rate to fall to 1/e of what it was.
    ///
    /// A wheel's friction is close enough to exponential, and this is the figure that makes a coast
    /// read as a wheel rather than as a scroll view: short enough that the document stops around
    /// where the eye expects, long enough that a flick is worth making.
    public static let decay: Double = 0.35

    /// The rate, in notches per second, below which the wheel is treated as stopped.
    ///
    /// A wheel creeping to a halt over half a minute is not a wheel, and the last notches of that
    /// creep are ones nobody asked for. It is also what bounds the coast: an exponential tail is
    /// infinite, and a wheel still turning while the user has moved on to something else would be
    /// scrolling a window nobody is looking at.
    public static let stalling: Double = 1.5

    /// The rate a flick launches the wheel at, from the speed of the finger as it left.
    public static func launch(pointsPerSecond speed: Double) -> Double {
        min(speed / ScrollNotch.travel, launchLimit)
    }

    /// The rate a coasting wheel is turning at, `seconds` after the finger left it.
    public static func rate(_ launch: Double, after seconds: Double) -> Double {
        launch * exp(-seconds / decay)
    }

    /// How long a flick keeps the wheel turning, in seconds.
    public static func duration(_ launch: Double) -> Double {
        guard launch > stalling else { return 0 }
        return decay * log(launch / stalling)
    }

    /// How far a flick carries, in notches, if it is not caught.
    ///
    /// The integral of ``rate(_:after:)`` over ``duration(_:)``, and the figure is worth knowing:
    /// about forty notches at the cap, which at a line to a notch is a page. That is what a flick
    /// is *for* — the two-finger drag is still the faster way across a document, and this is the
    /// way to move a screenful without leaving the corner the thumb is already in.
    public static func travel(_ launch: Double) -> Double {
        guard launch > stalling else { return 0 }
        return decay * (launch - stalling)
    }
}
