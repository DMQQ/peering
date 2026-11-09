import Foundation

/// How a person uses a Mac once a session is ready. `rawValue` is the analytics value and the stored value.
public enum SessionMode: String, CaseIterable, Sendable, Identifiable {
    case screen
    case workspace
    case remote

    public var id: String { rawValue }

    /// Whether the picture is shown in this mode: the other two stop it so a relay session costs almost nothing.
    public var showsPicture: Bool { self == .screen }
}
