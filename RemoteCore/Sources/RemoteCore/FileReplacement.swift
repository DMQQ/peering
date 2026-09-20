import Foundation

/// Replacing a file with one that arrives in pieces.
///
/// **One rule, and it is the whole of this file: a replacement lands in one move, or it does not
/// land at all.** A file written piece by piece *into place* is half the old contents and half the
/// new for as long as the transfer takes, and is the new contents only if nothing goes wrong. The
/// thing being replaced is usually somebody's script, so that is a state a machine must never be
/// in, and the answer is to build the replacement somewhere else and move it over in one step.
///
/// **In `RemoteCore` rather than in the host, because it is a rule rather than plumbing.** Whether
/// the scratch file lands beside the destination, and whether moving it over is one step, are
/// questions with answers that are wrong silently: a replacement that has quietly become a copy
/// across volumes works perfectly until the moment it does not, and nothing about the running app
/// says so. Both ends could use this and one of them has tests.
public enum FileReplacement {
    public enum Outcome: Equatable {
        case written(Int)
        case failure(String)
    }

    /// Where a replacement for `destination` waits while it arrives.
    ///
    /// **Beside the destination rather than in a temporary directory**, and that is the load-bearing
    /// part: the move at the end has to be a rename, and a rename across volumes is a copy. A
    /// temporary directory is on another volume more often than it sounds — `/tmp` and the home
    /// folder are separate volumes on some Macs, and every external drive is.
    ///
    /// **Under a name nothing will look for.** Hung off the front with a dot so it is hidden, and
    /// carrying a caller-supplied tag so that two transfers of the same path, or of two files whose
    /// names collide, cannot be appending into one file. Resolved first, so that a destination which
    /// is a symbolic link gets its replacement beside the file the link actually names.
    public static func stagingURL(for destination: URL, tag: String) -> URL {
        let target = destination.resolvingSymlinksInPath()
        return target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).peering-\(tag).part")
    }

    /// Moves a finished scratch file over its destination.
    ///
    /// Answers with how many bytes landed, taken from the file on disk rather than from a count
    /// kept alongside it: the number the user is shown should be the size of the thing they now
    /// have, and a count kept separately is a second answer that can disagree with the first.
    ///
    /// The destination's own permissions are kept, because a file that was executable has to stay
    /// executable after it is written over: an upload that quietly dropped the mode would leave a
    /// script that no longer runs, and nothing would say why.
    ///
    /// The scratch file is removed on every failure path. It is the caller's file to delete, but a
    /// caller that has to remember is a caller that leaves one behind when it forgets.
    public static func commit(staging: URL, to destination: URL) -> Outcome {
        let target = destination.resolvingSymlinksInPath()
        let existing = try? FileManager.default.attributesOfItem(atPath: target.path)

        // A folder is refused rather than written over, and refused here rather than earlier: the
        // destination may have become a folder during the transfer, and this is the last moment at
        // which that can still be noticed.
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
    /// Its own function rather than a share of the browsing failures, because the failures worth
    /// naming are not the same ones: reading a folder is refused by Files and Folders, and writing
    /// into one is refused by that *and* by the file being somebody else's, which is the case the
    /// sentence below has to cover without pretending to know which it was.
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
