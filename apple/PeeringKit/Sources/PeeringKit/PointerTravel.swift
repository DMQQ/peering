import CoreGraphics

/// Converts a picture's size into the Mac's points, the unit a joystick nudge is posted in.
public enum PointerTravel {
    /// Past this width a catalogue size is taken to be pixels of a 2x panel.
    public static let widestPointWidth: CGFloat = 2560

    /// The catalogue reports a MacBook display in points already (1512 wide) and a larger one in pixels, so only a size past ``widestPointWidth`` is halved. Halving always makes the drawn cursor run twice as far as the real pointer.
    public static func pointSize(forPicture pixels: CGSize) -> CGSize {
        pixels.width > widestPointWidth ? CGSize(width: pixels.width / 2, height: pixels.height / 2) : pixels
    }
}
