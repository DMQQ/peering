import Foundation

/// What a notch of the wheel is worth. `pixels` (`travel` times `pixelsPerPoint`) is the unit the host's wheel event is built in (`units: .pixel`); 24 pixels is about one line of text. `pixelsPerPoint` is shared with the two-finger drag so the two cannot disagree.
public enum ScrollNotch {
    public static let travel: Double = 12

    public static let pixelsPerPoint: Double = 2

    public static var pixels: Double { travel * pixelsPerPoint }
}

public struct ScrollWheelState {
    /// Travel not yet a notch, in points. Whole notches are subtracted, which is exact where summing fractions loses travel to rounding.
    private var carry: Double = 0

    public private(set) var delivered: Int = 0

    /// Public because the synthesized init would be internal.
    public init() {}

    /// Continuous, so the rim turns smoothly while only whole notches are sent.
    public var phase: Double { Double(delivered) + carry / ScrollNotch.travel }

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

    public mutating func roll(notches: Double) -> Int {
        roll(points: notches * ScrollNotch.travel)
    }

    /// The detent spring, run when the finger leaves: moves at most half a notch, so the wheel ends a whole number of notches from where it started.
    public mutating func seat() -> Int {
        let half = ScrollNotch.travel / 2
        let whole = carry > half ? delivered + 1 : (carry < -half ? delivered - 1 : delivered)
        carry = 0
        let moved = whole - delivered
        delivered = whole
        return moved
    }
}

public enum WheelSpin {
    /// Caps the flick: uncapped, the first fifth of a second would carry a whole document past the user.
    public static let launchLimit: Double = 120

    public static let decay: Double = 0.35

    /// Below this rate the wheel counts as stopped; this also bounds the exponential tail.
    public static let stalling: Double = 1.5

    public static func launch(pointsPerSecond speed: Double) -> Double {
        min(speed / ScrollNotch.travel, launchLimit)
    }

    public static func rate(_ launch: Double, after seconds: Double) -> Double {
        launch * exp(-seconds / decay)
    }

    public static func duration(_ launch: Double) -> Double {
        guard launch > stalling else { return 0 }
        return decay * log(launch / stalling)
    }

    public static func travel(_ launch: Double) -> Double {
        guard launch > stalling else { return 0 }
        return decay * (launch - stalling)
    }
}
