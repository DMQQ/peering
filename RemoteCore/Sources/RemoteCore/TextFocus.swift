import Foundation

/// Where the Mac's keyboard focus is, sent each time it moves to a different element.
///
/// Sent on every move rather than only when `isEditable` flips, so that going from one text field
/// to another still reaches the phone, which opens its keyboard again for the new field.
public struct TextFocus: Codable, Sendable, Equatable {
    /// Whether the focused element takes typing: a text field, a text area, or editable web content.
    public var isEditable: Bool

    public init(isEditable: Bool) {
        self.isEditable = isEditable
    }
}

/// What the focused text field on the Mac holds and where the insertion point is, sent whenever
/// either changes so the phone's field can show the same thing.
public struct FieldState: Codable, Sendable, Equatable {
    /// The field's text, or `nil` when it must not or cannot be read: a password field, an element
    /// that exposes no value, or text too long to be a field rather than a document.
    public var text: String?
    /// The selection in UTF-16 units, which is what both `AXSelectedTextRange` and `NSRange` count.
    public var selectionLocation: Int
    public var selectionLength: Int
    /// Where the insertion point is, in the captured picture's normalized space, or `nil` when the
    /// element does not say or it is outside the picture.
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
}
