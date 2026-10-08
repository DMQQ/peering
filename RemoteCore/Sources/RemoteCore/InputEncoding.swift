import Foundation

/// `CGEvent` construction stays in the host, where it is untestable by nature.
public enum InputEncoding {
    /// Not a documented limit, but applications commonly read only the first character of the string
    /// attached to a key event, so a long string in one event arrives truncated.
    public static let defaultUnicodeChunkSize = 20

    /// Measured in UTF-16 units, and a surrogate pair is never split: each half alone is invalid text.
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

            // A high surrogate in the last slot means its pair is the next unit: give the pair back to the next chunk.
            // `limit >= 2` guarantees `end > index + 1`, so this always makes progress.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }

            chunks.append(Array(units[index..<end]))
            index = end
        }
        return chunks
    }

    /// Clamped: `Int32(someDouble)` traps for NaN, infinity or out of range, and this arrives off the network.
    public static func wheelValue(_ delta: Double) -> Int32 {
        guard delta.isFinite else { return 0 }
        let rounded = delta.rounded()
        if rounded >= Double(Int32.max) { return Int32.max }
        if rounded <= Double(Int32.min) { return Int32.min }
        return Int32(rounded)
    }

    /// Left and right variants share a bit so a left-Shift release still clears a right-Shift press.
    public static func modifierBit(for keyCode: UInt16) -> Modifiers? {
        switch keyCode {
        case 54, 55: return .command    // right, left
        case 56, 60: return .shift      // left, right
        case 58, 61: return .option     // left, right
        case 59, 62: return .control    // left, right
        default: return nil
        }
    }

    /// Modifiers alone produce no character: an ordinary key-down for one leaves apps believing it is held.
    /// Wider than ``modifierBit(for:)``: caps lock and fn are flags changes too but have no `Modifiers` bit.
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
