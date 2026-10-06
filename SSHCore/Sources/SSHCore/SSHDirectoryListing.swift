import Foundation
import RemoteCore

/// What a provider said about a folder, in the one shape the browser draws. SFTP gives attributes for every entry and the `ls` fallback gives names only, and the browser must not learn the difference.
enum SSHDirectoryListing {
    /// The same cap as the Mac's browser: a directory like `/usr/bin` is thousands of rows crossing the shell's connection. The answer says it was cut.
    static let maximumEntries = 2_000

    /// Folders first, then Finder-style by name. The dot-entries are dropped here because SFTP hands them over and `ls` is only asked not to.
    static func normalise(
        _ entries: [RemoteDirectoryEntry]
    ) -> (entries: [RemoteDirectoryEntry], isTruncated: Bool) {
        let named = entries.filter { !$0.name.isEmpty && $0.name != "." && $0.name != ".." }
        let sorted = named.sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
        // Cut after the sort, so what is shown is the start of a real order.
        return (Array(sorted.prefix(maximumEntries)), sorted.count > maximumEntries)
    }

    /// `mode` is POSIX `st_mode`, type bits included. A symbolic link's type is settled by the caller, since the attributes describe the link, not its target.
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
            // The entry's own size, a folder's included, as `ls -l` prints it; the only size obtainable without reading the tree.
            size: Int64(size ?? 0),
            permissions: mode.map { permissions(type: typeCharacter(of: type), mode: $0) } ?? "",
            modified: modified
        )
    }

    /// `ls -p` marks folders with a slash, which cannot occur in a name, so folder-or-file is a fact; size, date and mode are absent, and a name containing a newline arrives as two rows (see the command in ``SSHFileService``).
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

    /// Mode bits as `ls -l` prints them, matching the Mac browser's `RemoteDirectoryEntry/permissions`. The type characters go further than the Mac's `l`, `d` and `-`, since a server's folder can hold a socket or fifo.
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
        // `s`/`S` and `t`/`T` replace the execute character; lowercase where execute is also set.
        var characters = Array(bits)
        if mode & 0o4000 != 0 { characters[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { characters[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { characters[8] = mode & 0o001 != 0 ? "t" : "T" }
        return String(type) + String(characters)
    }

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
