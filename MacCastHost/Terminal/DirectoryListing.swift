import Foundation
import RemoteCore

/// One folder's contents, for the two browsers this Mac serves.
enum DirectoryListing {
    static let maximumEntries = 2_000

    enum Outcome {
        case entries([RemoteDirectoryEntry], truncated: Bool)
        case failure(String)
    }

    /// No size among them: `URLResourceValues` has no key for the mode bits, so both come from one
    /// `attributesOfItem` instead, which is the call that has to be used anyway because `fileSize`
    /// answers nothing for a folder.
    private static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]

    static func entries(in directory: URL) -> Outcome {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(entryKeys),
                // Hidden entries are listed rather than skipped: which to show is the phone's
                // decision, and a filter here would be a second answer to a question the client
                // already answers. The SSH browser has its own idea of "hidden".
                options: []
            )
        } catch {
            return .failure(message(for: error))
        }

        // Folders first, then by name, and sorted here rather than on the phone so every client
        // shows the same order. `localizedStandardCompare` is how the Finder compares, so `file 10`
        // follows `file 9` rather than `file 1`.
        let entries = urls.compactMap(entry(for:)).sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
        // Cut after the sort, so what arrives is the beginning of a real order rather than whatever
        // order the filesystem handed over.
        return .entries(
            Array(entries.prefix(maximumEntries)),
            truncated: entries.count > maximumEntries
        )
    }

    /// One row, or nothing for an entry that could not be described.
    private static func entry(for url: URL) -> RemoteDirectoryEntry? {
        guard let values = try? url.resourceValues(forKeys: entryKeys) else { return nil }

        let isSymlink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false
        if isSymlink {
            // A link reports its own type rather than its target's, and a link to a folder is a
            // folder as far as a tap on the row goes. `fileExists` follows the link, which is the
            // question here, and only links pay for the second look.
            var pointsAtDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &pointsAtDirectory) {
                isDirectory = pointsAtDirectory.boolValue
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        return RemoteDirectoryEntry(
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            permissions: modeString(from: attributes, isDirectory: isDirectory, isSymlink: isSymlink),
            modified: values.contentModificationDate
        )
    }

    private static func modeString(
        from attributes: [FileAttributeKey: Any]?,
        isDirectory: Bool,
        isSymlink: Bool
    ) -> String {
        guard let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue else { return "" }

        let type = isSymlink ? "l" : (isDirectory ? "d" : "-")
        var bits = ""
        for (mask, letter) in [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ] {
            bits += mode & mask != 0 ? letter : "-"
        }
        // The three that sit on top of an execute bit and print in its place: `s` where it is set
        // too and `S` where it is not, likewise `t` and `T` for the sticky bit.
        var characters = Array(bits)
        if mode & 0o4000 != 0 { characters[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { characters[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { characters[8] = mode & 0o001 != 0 ? "t" : "T" }
        return type + String(characters)
    }

    /// macOS answers EPERM both when the consent prompt was declined and when it has not been shown
    /// yet, so the permission sentence names the setting rather than guessing which of the two it
    /// was. It is the only failure here the user can do anything about.
    static func message(forErrno code: Int32) -> String {
        switch code {
        case EPERM, EACCES:
            return "Peering is not allowed to read this. Allow Peering in Files and Folders under Privacy and Security on the Mac."
        case ENOENT:
            return "That is no longer there."
        case ENOTDIR:
            return "Part of that path is not a folder."
        default:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        }
    }

    static func message(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError: return message(forErrno: EPERM)
            case NSFileNoSuchFileError: return message(forErrno: ENOENT)
            default: break
            }
        }
        if error.domain == NSPOSIXErrorDomain { return message(forErrno: Int32(error.code)) }
        return error.localizedDescription
    }
}
