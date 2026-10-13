import Foundation

/// A replacement lands in one move or not at all.
public enum FileReplacement {
    public enum Outcome: Equatable {
        case written(Int)
        case failure(String)
    }

    /// Beside the destination, not in a temp dir: the final move must be a rename, and `/tmp` and home can be separate volumes.
    /// Tagged so two transfers of one path cannot append into one file; resolved first so a symlink destination stages beside its target.
    public static func stagingURL(for destination: URL, tag: String) -> URL {
        let target = destination.resolvingSymlinksInPath()
        return target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).peering-\(tag).part")
    }

    /// The byte count comes from the file on disk. The destination's permissions are kept, and the scratch file is removed on every failure path.
    public static func commit(staging: URL, to destination: URL) -> Outcome {
        let target = destination.resolvingSymlinksInPath()
        let existing = try? FileManager.default.attributesOfItem(atPath: target.path)

        // Refused here, not earlier: the destination may have become a folder during the transfer.
        if let existing, existing[.type] as? FileAttributeType == .typeDirectory {
            try? FileManager.default.removeItem(at: staging)
            return .failure("That is a folder, so a file cannot be written over it.")
        }

        let written = (try? FileManager.default.attributesOfItem(atPath: staging.path))?[.size] as? Int ?? 0

        // Qualified, because an unqualified `rename` inside a type resolves to a method before it
        // resolves to the C function, and the method that wins does not move a file.
        guard Darwin.rename(staging.path, target.path) == 0 else {
            // Read immediately: the next statement can overwrite `errno`.
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            return .failure(message(for: NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
        }

        if let mode = existing?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        return .written(written)
    }

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
