import Foundation
import RemoteCore

/// What a provider said about a folder, in the one shape the browser draws.
///
/// Both providers end up here, and that is the whole of what this file is for. SFTP answers with
/// the attributes of every entry; the one-off `ls` fallback answers with names and nothing else.
/// A browser that drew those two differently would be two browsers wearing one view — and the
/// view is ``FileBrowserPanel``, which knows about neither Citadel nor `ls` and must not learn.
///
/// Free of the network on purpose. Everything here is a function of what arrived, which is what
/// makes it the part of the SSH browser that can be tested without a server to point it at.
enum SSHDirectoryListing {
    /// How many entries one listing carries.
    ///
    /// The same cap the Mac's own browser applies, and chosen for the same reason: the listing
    /// crosses the same connection as the shell's output, and a directory like `/usr/bin` is
    /// several thousand rows the user is going to scroll past. The answer says it was cut, so the
    /// panel can say so too.
    static let maximumEntries = 2_000

    /// Entries in the order they are drawn, with the cap applied.
    ///
    /// Folders first, then by name, and compared the way a Finder compares them, so `file 10`
    /// follows `file 9` rather than `file 1` — the same sort the Mac's browser does. The two
    /// dot-entries are dropped here rather than by whoever asked, because SFTP hands them over
    /// and `ls` is only asked not to, and one of those two is not a promise.
    static func normalise(
        _ entries: [RemoteDirectoryEntry]
    ) -> (entries: [RemoteDirectoryEntry], isTruncated: Bool) {
        let named = entries.filter { !$0.name.isEmpty && $0.name != "." && $0.name != ".." }
        let sorted = named.sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
        // Cut after the sort, so what is shown is the beginning of a real order rather than
        // whatever order the server happened to hand over.
        return (Array(sorted.prefix(maximumEntries)), sorted.count > maximumEntries)
    }

    /// One row from what a server said about a name.
    ///
    /// `mode` is POSIX's, type bits and all: the SFTP attributes field carries what `stat` returns
    /// in `st_mode`, which is where both the permissions string and the answer to "does a tap on
    /// this open it" come from.
    ///
    /// A symbolic link reads as a link here and its *type* is settled by whoever called this —
    /// the listing attributes describe the link, not what it points at, and only a second look
    /// can say whether there is a folder on the other end.
    static func entry(
        name: String,
        mode: UInt32?,
        size: UInt64?,
        modified: Date?
    ) -> RemoteDirectoryEntry {
        let type = (mode ?? 0) & 0o170_000
        let isSymlink = type == 0o120_000
        let isDirectory = type == 0o040_000

        return RemoteDirectoryEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            // The entry's own size, a folder's included: the attributes describe the entry, and
            // the bytes they give for a directory are the ones `ls -l` prints beside it — the
            // same rule the Mac's browser follows, and the only size either of them can give
            // without reading the whole tree behind the row.
            size: Int64(size ?? 0),
            permissions: mode.map { permissions(type: typeCharacter(of: type), mode: $0) } ?? "",
            modified: modified
        )
    }

    /// The entries in a one-name-per-line listing.
    ///
    /// What this can recover and what it cannot is worth being exact about. `ls -p` appends a
    /// slash to a folder and to nothing else, and a slash cannot occur in a file name, so
    /// folder-or-file is a fact rather than a guess. Everything else is not here at all: no size,
    /// no date, no mode. And a name with a newline in it arrives as two rows, because the only
    /// thing separating one name from the next is the newline — see the command in
    /// ``SSHFileService`` for why that trade was taken.
    static func entries(fromListing output: String) -> [RemoteDirectoryEntry] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let isDirectory = line.hasSuffix("/")
            let name = isDirectory ? line.dropLast() : line[...]
            guard !name.isEmpty else { return nil }
            return RemoteDirectoryEntry(
                name: String(name),
                isDirectory: isDirectory,
                isSymlink: false,
                size: 0,
                permissions: "",
                modified: nil
            )
        }
    }

    /// The mode bits in the form `ls -l` prints them, type character and all.
    ///
    /// The same nine characters and the same three substitutions as the Mac's own browser writes,
    /// because `RemoteDirectoryEntry/permissions` is documented as "the form `ls -l` prints them"
    /// and two browsers disagreeing about that would make the field mean nothing. The type
    /// characters go one further than the Mac's, which only ever writes `l`, `d` and `-`: a
    /// server's folder can hold a socket or a fifo, and a row saying `-rw-r--r--` about one is
    /// simply a lie.
    static func permissions(type: Character, mode: UInt32) -> String {
        let mode = mode & 0o7_777
        var bits = ""
        for (mask, letter) in [
            (UInt32(0o400), "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ] {
            bits += mode & mask != 0 ? letter : "-"
        }
        // The three that sit on top of an execute bit and are printed in its place: `s` where the
        // execute bit is set too and `S` where it is not, and the same idea with `t` and `T` for
        // the sticky bit.
        var characters = Array(bits)
        if mode & 0o4000 != 0 { characters[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { characters[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { characters[8] = mode & 0o001 != 0 ? "t" : "T" }
        return String(type) + String(characters)
    }

    /// The character `ls -l` puts in the first column for this mode's type bits.
    private static func typeCharacter(of type: UInt32) -> Character {
        switch type {
        case 0o040_000: return "d"
        case 0o120_000: return "l"
        case 0o140_000: return "s"
        case 0o010_000: return "p"
        case 0o020_000: return "c"
        case 0o060_000: return "b"
        default: return "-"
        }
    }
}
