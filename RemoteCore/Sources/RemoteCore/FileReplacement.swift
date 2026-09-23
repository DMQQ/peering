import Foundation

/// Replacing a file with one that arrives in pieces.
///
/// One rule, and it is the whole of this file: a replacement lands in one move, or it does not land
/// at all. A file written piece by piece into place is half the old contents and half the new for as
/// long as the transfer takes, and the thing being replaced is usually somebody's script.
public enum FileReplacement {
    public enum Outcome: Equatable {
        case written(Int)
        case failure(String)
    }

    /// Where a replacement for `destination` waits while it arrives.
    ///
    /// Beside the destination rather than in a temporary directory: the move at the end has to be a
    /// rename, and a rename across volumes is a copy. `/tmp` and the home folder are separate volumes
    /// on some Macs.
    ///
    /// Dotted so it is hidden, and tagged so that two transfers of the same path cannot be appending
    /// into one file. Resolved first, so a destination which is a symbolic link gets its replacement
    /// beside the file the link actually names.
    public static func stagingURL(for destination: URL, tag: String) -> URL {
        let target = destination.resolvingSymlinksInPath()
        return target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).peering-\(tag).part")
    }

    /// Moves a finished scratch file over its destination.
    ///
    /// Answers with how many bytes landed, taken from the file on disk rather than from a count kept
    /// alongside it, which would be a second answer that can disagree with the first. The
    /// destination's own permissions are kept, so a file that was executable stays executable, and
    /// the scratch file is removed on every failure path.
    public static func commit(staging: URL, to destination: URL) -> Outcome {
        let target = destination.resolvingSymlinksInPath()
        let existing = try? FileManager.default.attributesOfItem(atPath: target.path)

        // A folder is refused rather than written over, and refused here rather than earlier: the
        // destination may have become a folder during the transfer, and this is the last moment at
        // which that can be noticed.
        if let existing, existing[.type] as? FileAttributeType == .typeDirectory {
            try? FileManager.default.removeItem(at: staging)
            return .failure("That is a folder, so a file cannot be written over it.")
        }

        let written = (try? FileManager.default.attributesOfItem(atPath: staging.path))?[.size] as? Int ?? 0

        // Qualified, because an unqualified `rename` inside a type resolves to a method before it
        // resolves to the C function, and the method that wins does not move a file.
        guard Darwin.rename(staging.path, target.path) == 0 else {
            // Read before anything else can overwrite it, which for `errno` means the very next
            // statement.
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            return .failure(message(for: NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
        }

        if let mode = existing?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        return .written(written)
    }

    /// What to tell the user when the filesystem refuses a write.
    ///
    /// Its own function rather than a share of the browsing failures: writing is refused both by
    /// Files and Folders and by the file being somebody else's, and the sentence below has to cover
    /// either without pretending to know which it was.
    public static func message(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return "Peering is not allowed to change that file. If it belongs to another user, save it somewhere else."
            case NSFileWriteOutOfSpaceError:
                return "There is not enough room on the Mac to save that."
            case NSFileNoSuchFileError:
                return "That folder is no longer there."
            default: break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case EPERM, EACCES:
                return message(for: NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError
                ))
            case ENOENT: return "That folder is no longer there."
            case ENOTDIR: return "Part of that path is not a folder."
            case ENOSPC: return "There is not enough room on the Mac to save that."
            default: break
            }
        }
        return error.localizedDescription
    }
}
