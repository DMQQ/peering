import Foundation

/// The rules for naming something inside a folder.
///
/// Both browsers ask the same two questions, one at the far end of a control channel and one at the
/// far end of an SFTP session, and two spellings of "is this a legal name" would be two chances to
/// let through on one side what the other refuses.
///
/// The phone decides and the machine checks: the browser holds the folder's listing, so it can pick
/// a name nothing is using, and the machine asks again rather than trusting, which is what stops a
/// client that has been got at naming `../.ssh/authorized_keys`.
public enum RemoteFileName {
    /// The longest a single name may be, counted in bytes.
    ///
    /// `NAME_MAX` on every filesystem either end is likely to be, and bytes rather than characters
    /// because that is the unit the limit is in: a name of 300 emoji is 1,200 bytes and the
    /// filesystem counts all of them. Otherwise it arrives as an `ENAMETOOLONG` on the far end,
    /// which is a sentence about the server rather than about the name.
    public static let maximumBytes = 255

    /// Whether a name may be used for a new file or a new name for an old one.
    ///
    /// Four refusals: empty is nothing to create; a slash is a path, and a path arriving where a
    /// name was expected is how a rename becomes a move; `.` and `..` are the two names every
    /// filesystem already means something by.
    ///
    /// Deliberately not refused: a leading dot (a hidden file is a file), a space, a newline, a
    /// quote, a `;`, a `$`. None is dangerous here, because the one place a name becomes shell
    /// script, ``ShellPath/quoted(_:)``, quotes it.
    public static func isValid(_ name: String) -> Bool {
        // Whitespace is trimmed before the empty test and nowhere else: a name of one space draws
        // as a blank row the user can never select again, while a name that merely has spaces is a
        // name, and `My Documents` is left alone.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.contains("/") else { return false }
        // A NUL cannot be in a path at all: every API that takes one will read it as the end of
        // the string, so a name holding one names something other than what is on screen.
        guard !name.utf8.contains(0) else { return false }
        return name.utf8.count <= maximumBytes
    }

    /// A name nothing in `existing` is using, spelled the way the Finder spells one.
    ///
    /// `New Folder`, then `New Folder 2`, then `New Folder 3`, unsuffixed first so that the first
    /// one made in a folder does not announce that it is the first.
    ///
    /// The lowest free number, not the next one after the highest: a folder where somebody deleted
    /// `New Folder 2` hands that name out again rather than leaving a permanent gap. The comparison
    /// is against the names as given, so a hand-made `New Folder 2` is respected.
    ///
    /// `base` arrives without its extension and `suffix` with it, so the number lands where the
    /// Finder puts it: `New File 2.txt` and not `New File.txt 2`.
    public static func available(
        base: String,
        extension suffix: String = "",
        among existing: some Sequence<String>
    ) -> String {
        // A set, because this is asked once per tap against a listing that can be two thousand
        // rows, and a linear scan per candidate would make the first free number quadratic.
        //
        // Folded, because APFS is case-insensitive by default: a folder holding a hand-made
        // `new folder` would otherwise be offered `New Folder`, and the user would be told a name
        // they never typed was taken. Strictly more cautious than a case-sensitive server needs.
        let taken = Set(existing.map { $0.lowercased() })

        let first = base + suffix
        guard taken.contains(first.lowercased()) else { return first }

        // From two, because one was just tried, and unbounded above because a folder holding every
        // number still has a next one.
        var number = 2
        while true {
            let candidate = "\(base) \(number)\(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}
