import CoreGraphics

extension CGSize {
    /// Whether two canvas sizes are the same canvas.
    public func matchesCanvas(_ other: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
