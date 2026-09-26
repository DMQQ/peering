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
