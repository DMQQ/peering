import Foundation

public enum TerminalMetrics {
    /// Approximations on purpose: one column out is invisible in a prompt, and the alternative is CoreText metrics on every layout pass.
    public static func cellWidth(for fontSize: CGFloat) -> CGFloat { fontSize * 0.6 }
    public static func cellHeight(for fontSize: CGFloat) -> CGFloat { fontSize * 1.2 }

    /// Tiny is the one that fits: a portrait phone holds eighty columns of seven-point text, which full-screen programs lay out for. Not the default because some people will not want it.
    public enum TextSize: Int, CaseIterable, Identifiable {
        case tiny = 7
        case small = 9
        case regular = 12
        case large = 15

        public var id: Int { rawValue }
        public var points: CGFloat { CGFloat(rawValue) }

        public var name: String {
            switch self {
            case .tiny: return String(localized: "Tiny")
            case .small: return String(localized: "Small")
            case .regular: return String(localized: "Default")
            case .large: return String(localized: "Large")
            }
        }

        public static func named(_ points: Int) -> TextSize {
            TextSize(rawValue: points) ?? .regular
        }
    }

    /// A full-screen program drawn for the fifty columns a portrait phone fits is broken (Claude Code's boxes, `htop` and `vim` assume eighty). Both logs scroll sideways, so the floor costs a pan.
    public static let minimumColumns = 80

    /// And the shortest, which is only ever reached by a keyboard covering most of the screen.
    public static let minimumRows = 6

    public static func columns(forWidth width: CGFloat, fontSize: CGFloat) -> Int {
        max(minimumColumns, Int(width / cellWidth(for: fontSize)))
    }

    public static func rows(forHeight height: CGFloat, fontSize: CGFloat) -> Int {
        max(minimumRows, Int(height / cellHeight(for: fontSize)))
    }
}
