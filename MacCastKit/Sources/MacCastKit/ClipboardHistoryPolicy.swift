import Foundation

/// What the phone keeps of the clipboard the Mac sends. The text arrives unasked and is written to UserDefaults, which is decoded in full at every launch, so one huge copy would slow every start.
public enum ClipboardHistoryPolicy {
    public static let maximumEntryBytes = 100_000

    public static func remembers(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumEntryBytes
    }
}
