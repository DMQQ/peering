import CoreGraphics
import Foundation

/// Converts a picture's size into the Mac's points, the unit a joystick nudge is posted in.
public enum PointerTravel {
    /// Past this width a catalogue size is taken to be pixels of a 2x panel.
    public static let widestPointWidth: CGFloat = 2560

    /// The catalogue reports a MacBook display in points already (1512 wide) and a larger one in pixels, so only a size past ``widestPointWidth`` is halved. Halving always makes the drawn cursor run twice as far as the real pointer.
    public static func pointSize(forPicture pixels: CGSize) -> CGSize {
        pixels.width > widestPointWidth ? CGSize(width: pixels.width / 2, height: pixels.height / 2) : pixels
    }

    /// Screen widths a second at full deflection and 1x. It was 1.5 on a straight line, which put even a light push past what a person can aim with.
    public static let widthsPerSecondAtFullDeflection = 0.8
    /// Above 1 so the first half of the stick is fine control and the speed arrives at the rim.
    public static let responseExponent = 1.6

    /// What fraction of full travel a stick pushed `deflection` of the way out (0 to 1) asks for.
    public static func response(forDeflection deflection: Double) -> Double {
        pow(min(max(deflection, 0), 1), responseExponent)
    }

    /// The Mac points to move for a stick at `offset` from its centre, held for `interval` seconds.
    public static func travel(offset: CGSize, radius: CGFloat, pointSize: CGSize, interval: TimeInterval) -> CGSize {
        let deflection = hypot(offset.width, offset.height) / radius
        guard deflection > 0, deflection.isFinite else { return .zero }
        let scale = response(forDeflection: Double(deflection)) / Double(deflection)
        let perSecond = widthsPerSecondAtFullDeflection * scale * interval
        return CGSize(
            width: Double(offset.width / radius) * perSecond * Double(pointSize.width),
            height: Double(offset.height / radius) * perSecond * Double(pointSize.height)
        )
    }
}
