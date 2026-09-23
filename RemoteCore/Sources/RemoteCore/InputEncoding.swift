import Foundation

/// Pure conversions between wire values and the primitives a synthetic event needs.
///
/// They live here rather than in the host because none of them touch CoreGraphics: the `CGEvent`
/// construction stays in the host, where it is untestable by nature.
public enum InputEncoding {
    /// The largest number of UTF-16 units a single keyboard event reliably carries.
    ///
    /// Not a documented limit, but applications commonly read only the first character of the string
    /// attached to a key event, so a long string in one event arrives truncated.
    public static let defaultUnicodeChunkSize = 20

    /// Splits text into chunks a single `CGEventKeyboardSetUnicodeString` can carry.
    ///
    /// Chunks are measured in UTF-16 units, the unit the API takes, and a surrogate pair is never
    /// split across two events: each half on its own is unpaired, which is not valid text, so an
    /// emoji would arrive as two broken halves.
    ///
    /// Returns `[]` for empty text, so a caller cannot post a keyboard event carrying nothing.
    public static func unicodeChunks(
        _ text: String,
        maxUnits: Int = defaultUnicodeChunkSize
    ) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        // A one-unit limit could not clear a surrogate pair, so it is raised to two rather than
        // allowed to loop without making progress.
        let limit = max(2, maxUnits)

        var chunks: [[UInt16]] = []
        var index = 0
        while index < units.count {
            var end = min(index + limit, units.count)

            // A high surrogate in the last slot means its pair is the next unit along.
            // Ending here would split them, so give the pair back to the following chunk.
            // `limit >= 2` guarantees `end > index + 1`, so this always makes progress.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }

            chunks.append(Array(units[index..<end]))
            index = end
        }
        return chunks
    }

    /// Converts a relative scroll delta into the integer a scroll wheel event takes.
    ///
    /// Clamped rather than converted directly: `Int32(someDouble)` traps for a NaN, an infinity or
    /// anything outside `Int32`'s range, and this value arrives straight off the network, so one
    /// malformed delta would take down the host process.
    public static func wheelValue(_ delta: Double) -> Int32 {
        guard delta.isFinite else { return 0 }
        let rounded = delta.rounded()
        if rounded >= Double(Int32.max) { return Int32.max }
        if rounded <= Double(Int32.min) { return Int32.min }
        return Int32(rounded)
    }

    /// The modifier a virtual keycode represents, or `nil` for an ordinary key.
    ///
    /// These are USB HID usage-derived virtual keycodes, fixed by the hardware layout and not
    /// affected by the active keyboard layout.
    ///
    /// The left and right variants deliberately share a bit: a flags change means the same thing
    /// either way, and collapsing them keeps a left-Shift release from failing to clear a
    /// right-Shift press.
    public static func modifierBit(for keyCode: UInt16) -> Modifiers? {
        switch keyCode {
        case 54, 55: return .command    // right, left
        case 56, 60: return .shift      // left, right
        case 58, 61: return .option     // left, right
        case 59, 62: return .control    // left, right
        default: return nil
        }
    }

    /// Keycodes that must be posted as `.flagsChanged` rather than as a key press.
    ///
    /// Pressing a modifier on its own produces no character and macOS reports it as a flags change,
    /// and an ordinary key-down for one leaves applications believing the modifier is held down with
    /// no matching release, which is exactly what the client's modifier-toggle buttons produce.
    ///
    /// Wider than ``modifierBit(for:)`` deliberately: caps lock and fn are reports of a flags change
    /// too, but have no `Modifiers` bit because a remote client cannot express them in a chord. They
    /// are still posted as flags changes, without affecting the tracked modifier state.
    public static func isModifierKeyCode(_ code: UInt16) -> Bool {
        switch code {
        case 54, 55,   // right command, left command
             56, 60,   // left shift, right shift
             57,       // caps lock
             58, 61,   // left option, right option
             59, 62,   // left control, right control
             63:       // fn
            return true
        default:
            return false
        }
    }
}
