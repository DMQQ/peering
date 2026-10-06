import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

private let fileLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

public struct SSHDirectory: Sendable, Equatable {
    /// Absolute and in the server's own spelling: the request may not have named a folder, and every later path is built from this one.
    public let path: String
    public let entries: [RemoteDirectoryEntry]
    public let isTruncated: Bool

    public init(path: String, entries: [RemoteDirectoryEntry], isTruncated: Bool) {
        self.path = path
        self.entries = entries
        self.isTruncated = isTruncated
    }
}

/// `data` is what to show and `totalBytes` is what is on disk; the bytes are already trimmed to a whole number of characters.
public struct SSHFileContents: Sendable, Equatable {
    public let path: String
    public let data: Data
    /// Decided by the server's bytes rather than the name. Defaulted because a write already knows the kind and the answer it gets back is about size.
    public let kind: RemoteFileKind
    public let totalBytes: Int
    /// Whether these bytes are the whole file. Saving a truncated read would replace the file with its first 128 KB, so this travels on the value for the editor and the writer to share.
    public let isTruncated: Bool

    public init(
        path: String,
        data: Data,
        kind: RemoteFileKind = .text,
        totalBytes: Int,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.data = data
        self.kind = kind
        self.totalBytes = totalBytes
        self.isTruncated = isTruncated
    }
}

/// Carried through the same stream as keystrokes because the connection object never leaves the task that opened it (see ``SSHSession``).
struct SSHBrowseRequest: Sendable {
    enum Kind: Sendable {
        case list
        case preview
        /// The whole file, not a patch: SFTP truncates and writes from zero, so handing over less than the file held destroys the difference (hence ``SSHFileContents/isTruncated``). `Data` because an upload is whatever the user picked.
        case write(contents: Data)
        case change(RemoteFileOperation)
    }

    let kind: Kind
    let path: String
    /// Resumed exactly once. A `CheckedContinuation` rather than an event on the session's stream, which is `.bufferingNewest(1024)` and would drop the oldest answer under pressure and leave the browser spinning.
    let continuation: CheckedContinuation<SSHBrowseResult, any Error>
}

enum SSHBrowseResult: Sendable {
    case listing(SSHDirectory)
    case contents(SSHFileContents)
    /// What is on the server now, read back after a write so a truncation by a quota or re-encoding does not look saved.
    case written(SSHFileContents)
    /// Composed on the server side because it is the only side that knows how much a recursive delete removed; the caller re-lists the folder.
    case changed(note: String)
}

/// Deliberately not `Sendable` and never stored: it holds the `SSHClient`, which cannot cross an isolation boundary. It lives inside the PTY closure's task, which is why there is no lock and a browse request is answered inline on the command loop.
final class SSHFileService {
    /// Settled on the first request so the fallback is probed once: a server's SFTP subsystem does not appear mid-session, and re-asking costs a stalled command loop.
    private enum Provider {
        case undecided
        case sftp
        case exec
    }

    private let client: SSHClient
    private var provider: Provider = .undecided
    private var start: String?

    init(client: SSHClient) {
        self.client = client
    }

    /// Never throws: the caller is a continuation that must be resumed exactly once.
    func answer(_ request: SSHBrowseRequest) async {
        do {
            switch request.kind {
            case .list:
                request.continuation.resume(returning: .listing(try await directory(at: request.path)))
            case .preview:
                request.continuation.resume(returning: .contents(try await contents(at: request.path)))
            case .write(let contents):
                request.continuation.resume(
                    returning: .written(try await write(contents, to: request.path))
                )
            case .change(let operation):
                request.continuation.resume(
                    returning: .changed(note: try await change(operation))
                )
            }
        } catch let error as SSHSessionError {
            request.continuation.resume(throwing: error)
        } catch {
            request.continuation.resume(throwing: SSHSessionError.browse(Self.describe(error)))
        }
    }

    // MARK: - Listing

    private func directory(at path: String) async throws -> SSHDirectory {
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

    private func sftpDirectory(at path: String) async throws -> SSHDirectory {
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
    private func execDirectory(at path: String) async throws -> SSHDirectory {
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

    private func startOverExec() async throws -> String {
        if let start { return start }
        let resolved = try await run("command pwd").trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.hasPrefix("/") else {
            throw SSHSessionError.browse("The server would not say where it starts.")
        }
        start = resolved
        return resolved
    }

    // MARK: - Preview

    /// SFTP only: a safe preview needs a `stat` before the bytes (follow links, regular file, capped read). The fallback would read first, and a read of a fifo or device never returns, wedging the command loop every keystroke goes through.
    private func contents(at path: String) async throws -> SSHFileContents {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so a file cannot be read here."
            )
        }

        return try await withSFTP { sftp in
            // `getAttributes` is SSH_FXP_STAT and follows a symbolic link, as the Mac's browser does.
            let attributes = try await sftp.getAttributes(at: path)
            // A folder, fifo, socket or device is an error or a wait, so the type is settled before opening; a response that does not say counts as not a file.
            guard let mode = attributes.permissions, mode & 0o170_000 == 0o100_000 else {
                throw SSHSessionError.browse("That is not a file, so there is nothing to show here.")
            }

            let totalBytes = Int(attributes.size ?? 0)

            let file = try await sftp.openFile(filePath: path, flags: .read)
            var data = Data()
            var kind = RemoteFileKind.text
            var limit = Self.maximumPreviewBytes

            /// A read may return less than asked, so it is asked again. A local function because this runs twice.
            func read(upTo cap: Int) async throws {
                while data.count < cap {
                    let length = UInt32(min(cap - data.count, Self.previewChunkBytes))
                    let piece = try await file.read(from: UInt64(data.count), length: length)
                    guard piece.readableBytes > 0 else { break }
                    data.append(contentsOf: piece.readableBytesView)
                }
            }

            do {
                // Twice, because the head of the file decides how much of the rest is worth carrying.
                let probe = attributes.size == nil
                    ? Self.binaryProbeBytes
                    : min(totalBytes, Self.binaryProbeBytes)
                try await read(upTo: probe)

                guard let sniffed = RemoteFileKind.sniff(prefix: data, path: path) else {
                    throw SSHSessionError.browse(
                        "That file is not text or a picture, so there is nothing to show here."
                    )
                }
                kind = sniffed
                limit = attributes.size == nil
                    ? (kind.isDrawn ? Self.maximumImagePreviewBytes : Self.maximumPreviewBytes)
                    : min(totalBytes, kind.isDrawn
                        ? Self.maximumImagePreviewBytes
                        : Self.maximumPreviewBytes)
                try await read(upTo: limit)
                try? await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            // A server that reported no size counts as truncated once the cap is reached: truncated content must never be written back.
            let truncated = data.count >= limit
                && (attributes.size == nil || totalBytes > data.count)

            // A raster image goes as read; text and SVG have one more check, after the handle is shut so it is closed exactly once.
            if kind == .image {
                return SSHFileContents(
                    path: path,
                    data: data,
                    kind: .image,
                    totalBytes: max(totalBytes, data.count),
                    isTruncated: truncated
                )
            }
            return try Self.text(
                data,
                kind: kind,
                path: path,
                totalBytes: max(totalBytes, data.count),
                isTruncated: truncated
            )
        }
    }

    /// SFTP only: sending file contents through a shell means quoting and here-documents that could write something other than what the user meant. `write | create | truncate` replaces the whole file and keeps its mode, so a saved script stays executable.
    private func write(_ contents: Data, to path: String) async throws -> SSHFileContents {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so a file cannot be saved here."
            )
        }

        return try await withSFTP { sftp in
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            )
            do {
                // `SFTPFile.write` splits into 32 KB pieces itself, so the whole buffer can be handed over.
                try await file.write(ByteBuffer(data: contents), at: 0)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            return SSHFileContents(path: path, data: contents, totalBytes: contents.count)
        }
    }

    // MARK: - Changing the tree

    /// SFTP only, for the reason a write is: an `rm` assembled from a name that arrived over a network is a way to delete the wrong thing.
    private func change(_ operation: RemoteFileOperation) async throws -> String {
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
    private static func create(
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
    private static func rename(
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
    private static func delete(
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
    private static let maximumDeleteEntries = 1_000

    /// Both refusals are the host's rules: a buffer that does not decode is not text, and up to three bytes come off the end first in case the cap cut a character. The NUL check lives in ``RemoteFileKind/sniff(prefix:path:)``; what is left is whether the whole read decodes.
    private static func text(
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

    // MARK: - The SFTP session

    /// A type of its own because a subsystem the server will not open means this host has no SFTP, while a folder it will not read says nothing about the next; only the first is worth falling back from.
    private struct SFTPUnavailable: Error {
        let reason: String
    }

    /// A session per request: Citadel's `listDirectory` never closes its directory handle, so a long-lived session leaks one server-side handle per folder viewed.
    private func withSFTP<T>(_ work: (SFTPClient) async throws -> T) async throws -> T {
        let sftp: SFTPClient
        do {
            // Citadel's own logger; this module logs through `os` and the SFTP client's chatter is left on whatever the app bootstrapped.
            sftp = try await client.openSFTP()
        } catch {
            throw SFTPUnavailable(reason: Self.describe(error))
        }

        do {
            let result = try await work(sftp)
            try? await sftp.close()
            return result
        } catch {
            try? await sftp.close()
            throw error
        }
    }

    /// SFTP describes the link rather than its target, so each link gets a second look to settle whether it opens. All at once, since `/usr/bin` is a thousand round trips; a link that cannot be reached stays a file.
    private static func resolvingLinks(
        _ entries: [RemoteDirectoryEntry],
        of directory: String,
        over sftp: SFTPClient
    ) async -> [RemoteDirectoryEntry] {
        let links = entries.filter(\.isSymlink).map(\.name)
        guard !links.isEmpty else { return entries }

        var targets: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for name in links {
                group.addTask {
                    let attributes = try? await sftp.getAttributes(at: childPath(name, of: directory))
                    let mode = attributes?.permissions ?? 0
                    return (name, mode & 0o170_000 == 0o040_000)
                }
            }
            for await (name, isDirectory) in group {
                targets[name] = isDirectory
            }
        }

        return entries.map { entry in
            guard entry.isSymlink, let isDirectory = targets[entry.name] else { return entry }
            return RemoteDirectoryEntry(
                name: entry.name,
                isDirectory: isDirectory,
                isSymlink: true,
                size: entry.size,
                permissions: entry.permissions,
                modified: entry.modified
            )
        }
    }

    // MARK: - Running a command

    /// `executeCommand` fails on a non-zero exit and on anything written to stderr, so an unreadable folder arrives as an error, and stderr is the sentence shown because it knows why.
    private func run(_ command: String) async throws -> String {
        do {
            let buffer = try await client.executeCommand(
                command,
                maxResponseSize: Self.maximumListingBytes
            )
            return String(buffer: buffer)
        } catch let error as TTYSTDError {
            let reason = String(buffer: error.message).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHSessionError.browse(
                reason.isEmpty ? "The server refused to list that folder." : reason
            )
        } catch {
            throw SSHSessionError.browse(Self.describe(error))
        }
    }

    /// The same bounds as the Mac's browser. The listing cap is here so the limit on what this end buffers is its own decision.
    private static let maximumListingBytes = 4 * 1024 * 1024
    private static let maximumPreviewBytes = 128 * 1024
    /// Sixty-four times the text cap: a photograph cut partway through is no picture at all.
    private static let maximumImagePreviewBytes = 8 * 1024 * 1024
    private static let previewChunkBytes = 32 * 1024
    private static let binaryProbeBytes = RemoteFileKind.probeBytes

    /// The two SFTP statuses with an actionable answer are a missing folder and one the user may not open; everything else uses the server's words.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case is SFTPUnavailable:
            // A listing never reaches here, since a session that will not open falls back to a command; a preview does, because it has nothing to fall back to.
            return "This server does not offer SFTP, so a file cannot be read here."
        case let error as SFTPError:
            switch error {
            case .errorStatus(let status):
                switch status.errorCode {
                case .noSuchFile: return "That is no longer there."
                case .permissionDenied: return "The server would not let this account read that."
                default: return status.message.isEmpty ? "The server refused." : status.message
                }
            case .missingResponse:
                return "The server did not answer."
            case .unsupportedVersion:
                return "This server speaks a version of SFTP this app does not."
            default:
                return "The folder could not be read."
            }
        case let failure as SSHClient.CommandFailed:
            return "The server refused to list that folder (status \(failure.exitCode))."
        case CitadelError.commandOutputTooLarge:
            return "That folder has more in it than this app will read at once."
        case CitadelError.channelCreationFailed, CitadelError.channelFailure:
            return "The server would not open another channel."
        default:
            return error.localizedDescription
        }
    }
}
