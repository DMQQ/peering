import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

extension SSHFileService {
    func directory(at path: String) async throws -> SSHDirectory {
        switch provider {
        case .sftp:
            return try await sftpDirectory(at: path)
        case .exec:
            return try await execDirectory(at: path)
        case .undecided:
            do {
                let directory = try await sftpDirectory(at: path)
                provider = .sftp
                return directory
            } catch let unavailable as SFTPUnavailable {
                // The subsystem is not there: no later request will find a different answer, so the fallback is settled here.
                fileLog.notice("SFTP unavailable, falling back to a listing command: \(unavailable.reason, privacy: .public)")
                provider = .exec
                return try await execDirectory(at: path)
            }
        }
    }

    func sftpDirectory(at path: String) async throws -> SSHDirectory {
        try await withSFTP { sftp in
            var directory = path
            var discovered: String?
            if !directory.hasPrefix("/") {
                if let start = self.start {
                    directory = start
                } else {
                    directory = try await sftp.getRealPath(atPath: directory)
                    discovered = directory
                }
            }

            let names = try await sftp.listDirectory(atPath: directory)
            // Flattened because a readdir may be answered in a batch of names.
            let entries = names.flatMap(\.components).map { component in
                SSHDirectoryListing.entry(
                    name: component.filename,
                    mode: component.attributes.permissions,
                    size: component.attributes.size,
                    modified: component.attributes.accessModificationTime?.modificationTime
                )
            }
            let listing = SSHDirectoryListing.normalise(entries)
            // After the cap, so the second look is taken only for rows that are shown.
            let resolved = await Self.resolvingLinks(listing.entries, of: directory, over: sftp)

            if let discovered { self.start = discovered }
            return SSHDirectory(
                path: directory,
                entries: resolved,
                isTruncated: listing.isTruncated
            )
        }
    }

    /// Names only: no size, date, mode or links, and a name with a newline arrives as two rows. Chosen to work anywhere, which is the only reason to have a fallback.
    func execDirectory(at path: String) async throws -> SSHDirectory {
        var directory = path
        if !directory.hasPrefix("/") {
            directory = try await startOverExec()
        }
        let output = try await run(Self.listingCommand(for: directory))
        let listing = SSHDirectoryListing.normalise(SSHDirectoryListing.entries(fromListing: output))
        return SSHDirectory(path: directory, entries: listing.entries, isTruncated: listing.isTruncated)
    }

    /// `-1`, `-p` and `-A` are all POSIX, the only standard covering a hardened box with BusyBox `ls`; `find -print0` and `-printf` are not portable. `-p` marks a folder and nothing else, so folder-or-file is a fact.
    /// `command` bypasses an alias that adds `--color`. `head` caps the answer at one row more than will be shown, so truncation is reportable; `ls` dies silently on SIGPIPE and its stderr is outside the pipe.
    /// Not private: the quoting is the difference between listing a folder and running whatever it is called, so a test pins it.
    static func listingCommand(for directory: String) -> String {
        "command ls -1pA -- \(ShellPath.quoted(directory))"
            + " | command head -n \(SSHDirectoryListing.maximumEntries + 1)"
    }

    func startOverExec() async throws -> String {
        if let start { return start }
        let resolved = try await run("command pwd").trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.hasPrefix("/") else {
            throw SSHSessionError.browse("The server would not say where it starts.")
        }
        start = resolved
        return resolved
    }
}
