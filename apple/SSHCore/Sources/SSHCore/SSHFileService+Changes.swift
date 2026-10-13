import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

extension SSHFileService {
    /// SFTP only, for the reason a write is: an `rm` assembled from a name that arrived over a network is a way to delete the wrong thing.
    func change(_ operation: RemoteFileOperation) async throws -> String {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so files cannot be changed here."
            )
        }

        // Read before the session opens because the closure is not isolated and `start` is state this instance owns.
        let start = self.start

        return try await withSFTP { sftp in
            switch operation {
            case .create(let path, let kind):
                return try await Self.create(at: path, kind: kind, over: sftp)
            case .rename(let path, let name):
                return try await Self.rename(at: path, to: name, over: sftp)
            case .delete(let path):
                return try await Self.delete(at: path, start: start, over: sftp)
            }
        }
    }

    /// The name is checked here as well as on the phone (``RemoteFileName/isValid(_:)``): a name holding a slash would become a move.
    static func create(
        at path: String,
        kind: RemoteEntryKind,
        over sftp: SFTPClient
    ) async throws -> String {
        let name = (path as NSString).lastPathComponent
        guard RemoteFileName.isValid(name) else {
            throw SSHSessionError.browse("That is not a name a file can have.")
        }

        switch kind {
        case .folder:
            try await sftp.createDirectory(atPath: path)
            return "created folder \(name)"

        case .file:
            // `forceCreate` is `SSH_FXF_EXCL` despite the name: it fails on an existing file, so a taken name is reported rather than truncated.
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .forceCreate]
            )
            try await file.close()
            return "created file \(name)"
        }
    }

    /// The destination is checked first: SFTP v3 has no no-overwrite flag and POSIX `rename` replaces it. A race remains for a file created between check and rename; closing it needs an extension not every server has.
    static func rename(
        at path: String,
        to name: String,
        over sftp: SFTPClient
    ) async throws -> String {
        guard RemoteFileName.isValid(name) else {
            throw SSHSessionError.browse("That is not a name a file can have.")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let old = (path as NSString).lastPathComponent
        let renamed = folder.isEmpty || folder == "/" ? "/" + name : folder + "/" + name

        if renamed == path { return "renamed \(old) to \(name)" }

        if (try? await sftp.getAttributes(at: renamed)) != nil {
            throw SSHSessionError.browse("Something with that name is already there.")
        }

        try await sftp.rename(at: path, to: renamed)
        return "renamed \(old) to \(name)"
    }

    /// The walk happens before any delete, so the failure modes are "nothing happened" and "it worked", never half a tree, and a folder too large is refused while intact.
    /// A symbolic link is removed as a link and never descended into; `getAttributes` follows links, so entry types come from the parent's listing.
    static func delete(
        at path: String,
        start: String?,
        over sftp: SFTPClient
    ) async throws -> String {
        let name = (path as NSString).lastPathComponent
        // Guard rails against a bug, not a user. Containment, not equality: with the login directory at `/home/dmq`, equality would leave `/home` deletable. The root is refused on its own, since the start may not be known yet.
        guard path != "/", !(start.map { pathContains($0, path) } ?? false) else {
            throw SSHSessionError.browse("That is too much of the server to delete.")
        }
        guard let root = try? await sftp.getAttributes(at: path) else {
            throw SSHSessionError.browse("That is no longer there.")
        }
        // A file or any link: one `remove`, no walking, which keeps a link's target out of it.
        guard root.permissions.map({ $0 & 0o170_000 == 0o040_000 }) == true else {
            try await sftp.remove(at: path)
            return "deleted \(name)"
        }

        // Each entry's type is decided in the walk: `getAttributes` at removal time follows links, so a link could come back as a folder and be `rmdir`'d.
        var doomed: [(path: String, isFolder: Bool)] = []
        var pending = [path]
        var count = 0

        while let folder = pending.popLast() {
            let listed = try await sftp.listDirectory(atPath: folder)
            for component in listed.flatMap(\.components) {
                let entry = component.filename
                guard entry != ".", entry != ".." else { continue }
                count += 1
                // Refused rather than truncated: half a delete is the outcome to avoid. The cap is also a time bound, since SFTP is a round trip per entry on the shared command loop.
                guard count <= maximumDeleteEntries else {
                    throw SSHSessionError.browse(
                        "That folder has more in it than this app will delete in one go (\(maximumDeleteEntries) entries). Delete it on the server instead."
                    )
                }

                let child = folder.hasSuffix("/") ? folder + entry : folder + "/" + entry
                // The entry's own type bits from the parent's listing: a link is a file here.
                let isFolder = (component.attributes.permissions ?? 0) & 0o170_000 == 0o040_000
                doomed.append((child, isFolder))
                // Descended into only for a real folder; walking through a link would delete the tree on the other side.
                if isFolder { pending.append(child) }
            }
        }

        // Reversed for a post-order delete without recursion: every child is removed before its parent.
        for entry in doomed.reversed() {
            if entry.isFolder {
                try await sftp.rmdir(at: entry.path)
            } else {
                try await sftp.remove(at: entry.path)
            }
        }
        try await sftp.rmdir(at: path)

        return doomed.isEmpty ? "deleted folder \(name)" : "deleted \(name) and \(doomed.count) more"
    }

    /// A thousand, a figure about the connection: each entry is a round trip on the loop every keystroke shares, so ten thousand files would freeze the terminal for minutes.
    static let maximumDeleteEntries = 1_000

    /// Both refusals are the host's rules: a buffer that does not decode is not text, and up to three bytes come off the end first in case the cap cut a character. The NUL check lives in ``RemoteFileKind/sniff(prefix:path:)``; what is left is whether the whole read decodes.
    static func text(
        _ data: Data,
        kind: RemoteFileKind,
        path: String,
        totalBytes: Int,
        isTruncated: Bool
    ) throws -> SSHFileContents {
        var trimmed = data
        var dropped = 0
        while dropped < 3, String(data: trimmed, encoding: .utf8) == nil, !trimmed.isEmpty {
            trimmed = trimmed.dropLast()
            dropped += 1
        }
        guard String(data: trimmed, encoding: .utf8) != nil else {
            throw SSHSessionError.browse(
                "That file is not text or a picture, so there is nothing to show here."
            )
        }
        return SSHFileContents(
            path: path,
            data: trimmed,
            kind: kind,
            totalBytes: totalBytes,
            isTruncated: isTruncated
        )
    }
}
