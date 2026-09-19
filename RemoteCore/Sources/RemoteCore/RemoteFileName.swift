import Foundation

/// The rules for naming something inside a folder.
///
/// Both browsers make files and folders now — one at the far end of a control channel, one at
/// the far end of an SFTP session — and both of them ask the same two questions before they do.
/// The questions are pure, so they live here, in the spirit of ``ShellPath``: it was lifted into
/// this module when the SSH browser turned out to need the same quoting for a different reason,
/// and this is the same move for the same reason. Two spellings of "is this a legal name" would
/// be two chances to let something through on one side that the other side refuses.
///
/// **The phone decides and the machine checks.** The browser is the side holding the folder's
/// listing, so it is the side that can pick a name nothing is using; the machine it is talking to
/// is the side that has to live with the result, so it asks again rather than trusting. Neither
/// check is redundant: the first is what stops a user being told "that name is taken" about a
/// name they never chose, and the second is what stops a client that has been got at from naming
/// something `../.ssh/authorized_keys`.
public enum RemoteFileName {
    /// The longest a single name may be, counted in bytes.
    ///
    /// `NAME_MAX` on every filesystem either end is likely to be, and counted in bytes rather
    /// than characters because that is the unit the limit is actually in: a name of 300 emoji is
    /// 1,200 bytes and the filesystem counts all of them. Refused here rather than discovered as
    /// an `ENAMETOOLONG` on the far end, which arrives as a sentence about the server rather than
    /// about the name.
    public static let maximumBytes = 255

    /// Whether a name may be used for a new file or a new name for an old one.
    ///
    /// Four refusals, and each is a different mistake. Empty is nothing to create. A slash is not
    /// a name at all but a path, and a path arriving where a name was expected is how a rename
    /// becomes a move — across folders, out of the folder, anywhere the sender likes. `.` and
    /// `..` are the two names every filesystem already means something by, and neither is
    /// something a user is trying to create.
    ///
    /// Deliberately *not* refused: a leading dot (a hidden file is a file), a space, a newline, a
    /// quote, a `;`, a `$`. All of them are legal in a name on every Unix, all of them are things
    /// a user may legitimately type, and none of them is dangerous here for the reason this is
    /// not a shell: a path reaches the far end as a path, and the one place it becomes a line of
    /// shell script — ``ShellPath/quoted(_:)`` — quotes it.
    public static func isValid(_ name: String) -> Bool {
        // Whitespace is trimmed before the empty test and nowhere else. A name of one space is a
        // file the user can never see, select or rename again from this panel — it draws as a
        // blank row — so it is refused rather than quietly tidied into something they did not
        // type. A name that merely *has* spaces is a name, and `My Documents` is left alone.
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
    /// `New Folder`, then `New Folder 2`, then `New Folder 3`. Unsuffixed first because the first
    /// one made in a folder should not announce that it is the first; numbered rather than
    /// stamped with a date or a random word because the point of the name is that the user is
    /// about to change it, and a name that is only a placeholder should be the easiest possible
    /// thing to select and type over.
    ///
    /// **The lowest free number, not the next one after the highest.** A folder where somebody
    /// deleted `New Folder 2` should hand that name out again rather than leaving a permanent gap
    /// that makes the count look wrong. The comparison is against the names *as given*, so a
    /// folder holding a hand-made `New Folder 2` is respected rather than collided with — which
    /// is the case that matters, since that is a name a person chose.
    ///
    /// `base` arrives without its extension and `suffix` with it, so that the number lands where
    /// the Finder puts it: `New File 2.txt` and not `New File.txt 2`, which is a different file
    /// as far as anything that reads extensions is concerned.
    public static func available(
        base: String,
        extension suffix: String = "",
        among existing: some Sequence<String>
    ) -> String {
        // A set, because this is asked once per tap against a listing that can be two thousand
        // rows and a linear scan per candidate would make the first free number quadratic.
        //
        // **Folded, because the Mac's filesystem is.** APFS is case-insensitive by default, so a
        // folder holding a hand-made `new folder` would otherwise be offered `New Folder`, the Mac
        // would refuse it as already there, and the user would be told a name they never typed was
        // taken. Strictly *more* cautious than a case-sensitive server needs, which costs a
        // number: `New Folder 2` in a folder where `NEW FOLDER` exists. That is the right way
        // round — the alternative invents a collision the user cannot explain or fix.
        //
        // Lowercasing rather than a full fold, because the candidates this generates are ASCII and
        // the only question is whether some existing name collides with one.
        let taken = Set(existing.map { $0.lowercased() })

        let first = base + suffix
        guard taken.contains(first.lowercased()) else { return first }

        // From two, because one was just tried, and unbounded above because the only honest
        // answer to a folder holding every number is the next one.
        var number = 2
        while true {
            let candidate = "\(base) \(number)\(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}
