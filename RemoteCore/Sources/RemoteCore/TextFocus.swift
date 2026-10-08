import Foundation

public struct TextFocus: Codable, Sendable, Equatable {
    public var isEditable: Bool

    public init(isEditable: Bool) {
        self.isEditable = isEditable
    }
}

/// What the focused text field on the Mac holds and where the insertion point is, sent whenever
/// either changes so the phone's field can show the same thing.
public struct FieldState: Codable, Sendable, Equatable {
    public var text: String?
    public var selectionLocation: Int
    public var selectionLength: Int
    public var caret: NormalizedPoint?

    public init(
        text: String?,
        selectionLocation: Int,
        selectionLength: Int,
        caret: NormalizedPoint?
    ) {
        self.text = text
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.caret = caret
    }

    /// The selection as the phone's field can take it. The values arrive from the Mac, and a range outside the text is an exception in UIKit.
    public func selection(inTextOfLength length: Int) -> (location: Int, length: Int) {
        let location = min(max(selectionLocation, 0), length)
        return (location, min(max(selectionLength, 0), length - location))
    }
}
