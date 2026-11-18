import CoreGraphics

/// What the screen's proportions say about how a session should be laid out.
public enum ScreenShape {
    /// A phone-idiom screen that is close to square (the foldable's), where the Mac's wide picture leaves bands above and below that a column of controls can use. Taller than 1.7:1 is an ordinary phone.
    public static func isBookShaped(size: CGSize) -> Bool {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard short > 0 else { return false }
        return long / short < 1.7
    }
}
