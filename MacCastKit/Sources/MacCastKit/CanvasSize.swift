import CoreGraphics

extension CGSize {
    /// Whether two canvas sizes are the same canvas.
    ///
    /// **Within two points, because the Mac rounds the canvas it builds to even.** A `420v` surface
    /// is two planes and the chroma plane is half the size, so an encoder asked for an odd canvas
    /// produces the even one below it — and a canvas that came back a pixel narrower would
    /// otherwise never match the arrangement it was asked for, which leaves its tiles unclickable
    /// on a picture that is unmistakably there. Two points is nothing beside the difference this is
    /// asked about, which is arrangements of different shapes.
    ///
    /// The canvas is the identity a picture states about itself: it is the one thing about an
    /// arrangement the Mac could not have got from anywhere but the ask.
    public func matchesCanvas(_ other: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
