import Foundation

/// What a notch of the wheel is worth, in the two units that have to agree.
///
/// The wheel is a notched control: a mouse wheel reports whole detents rather than how far a finger
/// moved, and a detent is a fixed amount of document. Everything here is one of those amounts.
///
/// - ``travel`` is how far a finger moves to earn one notch.
/// - ``pixelsPerPoint`` is this screen's one scale from a finger's travel to the Mac's content.
///   Shared with the two-finger drag, so the two controls cannot disagree about what a centimetre
///   of thumb is worth.
/// - ``pixels`` is their product, in the unit the host's wheel event is built in (`units: .pixel`).
///   Derived rather than written down, so the three cannot drift apart.
///
/// Twenty-four pixels is about a line of text, which is the reason for the number: one notch is
/// one line.
public enum ScrollNotch {
    /// Points of finger travel for one notch, about a thumb tip's width.
    public static let travel: Double = 12

    /// Pixels of the Mac's content for a point of finger travel, borrowed from the two-finger drag
    /// rather than kept as a second scale of the wheel's own.
    public static let pixelsPerPoint: Double = 2

    /// Pixels of the Mac's content for one notch: what the host is told to scroll.
    public static var pixels: Double { travel * pixelsPerPoint }
}

/// The wheel's own state: how far it has turned, and how much of that has been sent.
///
/// A type rather than view state, so `MacCastTests` can check the arithmetic without a phone.
public struct ScrollWheelState {
    /// Travel that has not earned a notch yet, in points.
    ///
    /// In points rather than notches: subtracting whole notches from the travel is exact where
    /// dividing each sample by the notch and adding the fractions loses travel to rounding.
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
    /// Continuous, so the rim turns smoothly while the Mac is only ever sent whole notches. Derived
    /// rather than tracked, so no second number can disagree about where the wheel is.
    public var phase: Double { Double(delivered) + carry / ScrollNotch.travel }

    /// Turns the wheel by a finger's travel, in points, and returns the whole notches that earned.
    ///
    /// Usually zero: most samples of a drag are part of the notch being rolled rather than a notch
    /// of their own.
    public mutating func roll(points: Double) -> Int {
        carry += points
        var whole = 0
        // Loops rather than a division: a fast flick covers thirty points between two frames, and
        // subtracting the notch is exact where dividing by it is not.
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
    /// The detent spring, run when the finger leaves: it costs at most half a notch and leaves the
    /// wheel a whole number of notches from where it started, so the arrows above and below always
    /// deliver exactly one.
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
/// A rate that decays exponentially, so a flick covers distance and then comes to rest. A touch on
/// the wheel catches it.
public enum WheelSpin {
    /// The fastest a flick can launch the wheel, in notches per second.
    ///
    /// Caps the flick that is not ordinary: without it the first fifth of a second would carry a
    /// whole document past the user.
    public static let launchLimit: Double = 120

    /// Seconds for the rate to fall to 1/e of what it was.
    public static let decay: Double = 0.35

    /// The rate, in notches per second, below which the wheel is treated as stopped.
    ///
    /// Also what bounds the coast, since an exponential tail is infinite.
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
    /// The integral of ``rate(_:after:)`` over ``duration(_:)``: about forty notches at the cap,
    /// which at a line to a notch is a page.
    public static func travel(_ launch: Double) -> Double {
        guard launch > stalling else { return 0 }
        return decay * (launch - stalling)
    }
}
