import Foundation

/// Naming rules shared by both browsers (control channel and SFTP). The phone picks a name and the machine re-checks it, which stops a tampered client naming `../.ssh/authorized_keys`.
public enum RemoteFileName {
    /// `NAME_MAX`, counted in bytes because that is the unit: 300 emoji are 1,200 bytes and the far end would answer `ENAMETOOLONG`.
    public static let maximumBytes = 255

    /// Refuses empty, anything with a slash (a rename would become a move), `.` and `..`. A leading dot, spaces and shell characters are fine because ``ShellPath/quoted(_:)`` quotes names.
    public static func isValid(_ name: String) -> Bool {
        // Trimmed only for the empty test: a one-space name is an unselectable blank row, but `My Documents` stays.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.contains("/") else { return false }
        // NUL ends a path string in every API, so the name would not be what is on screen.
        guard !name.utf8.contains(0) else { return false }
        return name.utf8.count <= maximumBytes
    }

    /// A free name spelled like the Finder: `New Folder`, `New Folder 2`, ... Takes the lowest free number, so a deleted `New Folder 2` is reused. `base` has no extension and `suffix` does, so the number lands as `New File 2.txt`.
    public static func available(
        base: String,
        extension suffix: String = "",
        among existing: some Sequence<String>
    ) -> String {
        // A set, since a listing can hold thousands of rows.
        // Folded because APFS is case-insensitive: `new folder` must make `New Folder` count as taken.
        let taken = Set(existing.map { $0.lowercased() })

        let first = base + suffix
        guard taken.contains(first.lowercased()) else { return first }

        var number = 2
        while true {
            let candidate = "\(base) \(number)\(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}
