import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

private let fileLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// One folder on a server, as the browser draws it.
public struct SSHDirectory: Sendable, Equatable {
    /// Where the folder actually is: absolute, and in the server's own spelling.
    ///
    /// Carried because the request may not have named a folder at all. A browser opens at
    /// "wherever a login starts", which only the server can turn into a path — and every path
    /// the browser shows afterwards, in its breadcrumbs and in the next request it makes, is
    /// built from this one.
    public let path: String
    public let entries: [RemoteDirectoryEntry]
    /// The server had more than ``SSHDirectoryListing/maximumEntries`` and the rest was not sent.
    public let isTruncated: Bool

    public init(path: String, entries: [RemoteDirectoryEntry], isTruncated: Bool) {
        self.path = path
        self.entries = entries
        self.isTruncated = isTruncated
    }
}

/// A file on a server, as far as it was read.
///
/// `data` is what to show and `totalBytes` is what is on disk, which is the same pair the Mac's
/// browser sends: a preview that stopped at the cap says so, and one that reached the end does
/// not. The bytes are already trimmed to a whole number of characters — see
/// ``SSHFileService/text(_:path:totalBytes:)``.
public struct SSHFileContents: Sendable, Equatable {
    public let path: String
    public let data: Data
    public let totalBytes: Int

    public init(path: String, data: Data, totalBytes: Int) {
        self.path = path
        self.data = data
        self.totalBytes = totalBytes
    }
}

/// One question about the server's files, and where its answer goes.
///
/// Carried through the same stream as keystrokes rather than over a channel of its own, because
/// everything that can answer it — the SFTP subsystem, a one-off command, the shell itself — has
/// to be asked through the connection object, and that object never leaves the task that opened
/// it. See ``SSHSession`` for why that is not a limitation to be worked around.
struct SSHBrowseRequest: Sendable {
    enum Kind: Sendable {
        case list
        case preview
    }

    let kind: Kind
    let path: String
    /// Resumed exactly once, by whoever answers. A `CheckedContinuation` rather than an event on
    /// the session's stream: that stream is `.bufferingNewest(1024)` and drops the *oldest*
    /// element when it overflows, so under pressure the answer to an older request would be the
    /// one thrown away. A dropped reply is a browser that spins forever with nothing to say.
    let continuation: CheckedContinuation<SSHBrowseResult, any Error>
}

enum SSHBrowseResult: Sendable {
    case listing(SSHDirectory)
    case contents(SSHFileContents)
}

/// The folder tree at the far end of a connection.
///
/// Deliberately not `Sendable`, and deliberately never stored anywhere: it holds the `SSHClient`,
/// which is the one thing in this module that cannot cross an isolation boundary — the same
/// reason ``SSHSession`` keeps its client inside the task that dialled. So this is created inside
/// that task's PTY closure, used from the command loop that lives there, and dropped when the
/// shell ends. That is the same confinement the client itself is under, which is why there is no
/// lock here and no `@unchecked` box, and it is also why a browse request is answered inline on
/// the command loop rather than by a task of its own.
final class SSHFileService {
    /// Which provider answered last, so the fallback is probed once rather than on every
    /// navigation. Settled on the first request and never revisited: a server's SFTP subsystem
    /// does not appear halfway through a session, and re-asking a question the server has already
    /// said no to costs a stalled command loop each time.
    private enum Provider {
        case undecided
        case sftp
        case exec
    }

    private let client: SSHClient
    private var provider: Provider = .undecided
    /// Where the browser opens: the server's own idea of where a session starts. Resolved once,
    /// because nothing the user does to a browser changes it.
    private var start: String?

    init(client: SSHClient) {
        self.client = client
    }

    /// Answers one request, and resumes whoever asked. Never throws: the caller is a continuation
    /// that has to be resumed exactly once, and an error is a kind of answer.
    func answer(_ request: SSHBrowseRequest) async {
        do {
            switch request.kind {
            case .list:
                request.continuation.resume(returning: .listing(try await directory(at: request.path)))
            case .preview:
                request.continuation.resume(returning: .contents(try await contents(at: request.path)))
            }
        } catch let error as SSHSessionError {
            request.continuation.resume(throwing: error)
        } catch {
            request.continuation.resume(throwing: SSHSessionError.browse(Self.describe(error)))
        }
    }

    // MARK: - Listing

    /// One folder's contents, from whichever provider this server turned out to have.
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
                // The subsystem is not there. Nothing about this *request* failed — no folder was
                // asked about and no folder refused — and no later request will find a different
                // answer, so the fallback is settled on here, once.
                fileLog.notice("SFTP unavailable, falling back to a listing command: \(unavailable.reason, privacy: .public)")
                provider = .exec
                return try await execDirectory(at: path)
            }
        }
    }

    /// A listing over SFTP, which is the one that carries attributes.
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
            // Flattened rather than mapped, because one message may carry several names: the
            // protocol allows a server to answer a readdir with a batch, and the types say so
            // even though every server in practice sends one at a time.
            let entries = names.flatMap(\.components).map { component in
                SSHDirectoryListing.entry(
                    name: component.filename,
                    mode: component.attributes.permissions,
                    size: component.attributes.size,
                    modified: component.attributes.accessModificationTime?.modificationTime
                )
            }
            let listing = SSHDirectoryListing.normalise(entries)
            // After the cap, so the second look is taken for the rows that are actually shown
            // and not for a folder's whole contents.
            let resolved = await Self.resolvingLinks(listing.entries, of: directory, over: sftp)

            if let discovered { self.start = discovered }
            return SSHDirectory(
                path: directory,
                entries: resolved,
                isTruncated: listing.isTruncated
            )
        }
    }

    /// A listing from a one-off command, for a server that will not open the SFTP subsystem.
    ///
    /// Names only, and the trade is worth stating plainly. SFTP answers with a `stat` per entry —
    /// size, date, mode, and the difference between a link and the thing it points at. This
    /// answers with names, and one of them per line is all it can do: a folder of symlinks comes
    /// back as folders-and-files with no links in it, every row says nothing about its size or
    /// its date, and a name with a newline in it arrives as two rows.
    ///
    /// The command is ``SSHFileService/listingCommand(for:)``. It is chosen to be the one that
    /// works *anywhere*, because that is the only reason to have a fallback at all.
    private func execDirectory(at path: String) async throws -> SSHDirectory {
        var directory = path
        if !directory.hasPrefix("/") {
            directory = try await startOverExec()
        }
        let output = try await run(Self.listingCommand(for: directory))
        let listing = SSHDirectoryListing.normalise(SSHDirectoryListing.entries(fromListing: output))
        return SSHDirectory(path: directory, entries: listing.entries, isTruncated: listing.isTruncated)
    }

    /// The listing command, and why it is this one.
    ///
    /// `-1` one name per line, `-p` a slash after a folder, `-A` everything except `.` and `..`:
    /// all three are POSIX, and POSIX is the only standard that covers a hardened box whose `ls`
    /// is BusyBox's and whose `find` is not GNU's. The alternatives were weighed and lost on
    /// portability rather than on quality — `find -print0` survives a name containing a newline
    /// and is a common extension rather than a standard one, and `find -printf` is GNU-only — so
    /// this takes the parse that can be fooled for the chance of running at all. What survives
    /// the trade is exact where it matters most: `-p` marks a folder and nothing else, and a
    /// slash cannot occur in a file name, so folder-or-file is a fact rather than a guess.
    ///
    /// `command` bypasses an alias or a shell function that might have been taught to add
    /// `--color`, which would put escape sequences around every name. And `head` caps the answer
    /// at one row more than will be shown, which is what makes the truncation reportable: a
    /// directory with a hundred thousand entries in it crosses the wire as two thousand rows and
    /// a listing that says it was cut, rather than as several megabytes and a failure. Losing the
    /// tool half way through does not lose the listing either — `ls` dies on SIGPIPE without a
    /// word, which is why the pipeline is safe here — and its stderr, which is where an
    /// unreadable folder reports through, is not part of the pipe and still arrives.
    /// Not private, because it is the one string in this file worth pinning with a test: the
    /// quoting in it is the difference between listing a folder and running whatever it is called.
    static func listingCommand(for directory: String) -> String {
        "command ls -1pA -- \(ShellPath.quoted(directory))"
            + " | command head -n \(SSHDirectoryListing.maximumEntries + 1)"
    }

    /// The same, for a server that has no SFTP to ask.
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

    /// A file's text, for the browser's preview.
    ///
    /// SFTP only, and that is a decision rather than an omission. Every rule that makes a preview
    /// safe needs a `stat` *before* the bytes are read: that the path follows a symbolic link,
    /// that the thing at the end of it is a regular file, and that the read is capped. The
    /// fallback has no `stat` — it would have to read first and ask afterwards, which on a fifo or
    /// a device is a read that never returns. This runs on the command loop that every keystroke
    /// goes through, so one tap on such a file would wedge the terminal until the connection
    /// dropped. So: a server without SFTP browses and does not preview, and says so.
    private func contents(at path: String) async throws -> SSHFileContents {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so a file cannot be read here."
            )
        }

        return try await withSFTP { sftp in
            // `getAttributes` is SSH_FXP_STAT, which follows a symbolic link: a link to a text
            // file is a text file to anyone looking at it, which is the rule the Mac's browser
            // follows and the reason it stats instead of reading resource values.
            let attributes = try await sftp.getAttributes(at: path)
            // A folder, a fifo, a socket or a device has no text in it and reading one is either
            // an error or a wait, so the type is settled before anything is opened. A response
            // that does not say what the thing is counts as "not a file": the alternative is
            // reading something on the strength of a field the server chose not to send.
            guard let mode = attributes.permissions, mode & 0o170_000 == 0o100_000 else {
                throw SSHSessionError.browse("That is not a file, so there is nothing to show here.")
            }

            let totalBytes = Int(attributes.size ?? 0)
            let limit = attributes.size == nil
                ? Self.maximumPreviewBytes
                : min(totalBytes, Self.maximumPreviewBytes)

            let file = try await sftp.openFile(filePath: path, flags: .read)
            var data = Data()
            do {
                // A read is allowed to return less than it was asked for, so it is asked again
                // until the cap or the end of the file. The Mac's own reader loops for the same
                // reason: for a regular file it never does, and the loop costs one comparison.
                while data.count < limit {
                    let length = UInt32(min(limit - data.count, Self.previewChunkBytes))
                    let piece = try await file.read(from: UInt64(data.count), length: length)
                    guard piece.readableBytes > 0 else { break }
                    data.append(contentsOf: piece.readableBytesView)
                }
                try? await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            // Checked after the handle is shut rather than before it, so that a file whose bytes
            // turn out not to be text has still been closed exactly once on the way out.
            return try Self.text(data, path: path, totalBytes: max(totalBytes, data.count))
        }
    }

    /// The bytes of a preview, checked the way the Mac's own reader checks them.
    ///
    /// Three refusals and one trim, all four of them the host's rules rather than new ones: a NUL
    /// byte near the start is what `file` calls binary and what no text view can draw; a buffer
    /// that does not decode is not text either; and up to three bytes come off the end first, for
    /// the case where the read stopped at the cap rather than at the end of the file and the cut
    /// landed inside a character. Calling a text file binary because it was a long one is exactly
    /// the wrong answer.
    private static func text(_ data: Data, path: String, totalBytes: Int) throws -> SSHFileContents {
        guard !data.prefix(binaryProbeBytes).contains(0) else {
            throw SSHSessionError.browse("That file is not text, so there is nothing to show here.")
        }
        var trimmed = data
        var dropped = 0
        while dropped < 3, String(data: trimmed, encoding: .utf8) == nil, !trimmed.isEmpty {
            trimmed = trimmed.dropLast()
            dropped += 1
        }
        guard String(data: trimmed, encoding: .utf8) != nil else {
            throw SSHSessionError.browse("That file is not text, so there is nothing to show here.")
        }
        return SSHFileContents(path: path, data: trimmed, totalBytes: totalBytes)
    }

    // MARK: - The SFTP session

    /// Thrown instead of an SFTP error when the *session* could not be opened.
    ///
    /// A type of its own rather than a check on which error came back, because the two failures
    /// look identical from here and mean opposite things: a subsystem the server will not open
    /// says this host has no SFTP at all, while a folder the server will not read says nothing
    /// about the next folder. Only the first is worth falling back from.
    private struct SFTPUnavailable: Error {
        let reason: String
    }

    /// Opens a session, does one thing with it, and closes it.
    ///
    /// A session per request, and not one kept for the life of the connection. Citadel's own
    /// `listDirectory` opens a directory handle and never closes it — there is no `closedir` on
    /// its client at all — so a session held open and used for navigation leaks one server-side
    /// handle per folder the user looks at, and a server that caps them eventually stops
    /// answering. Opening and closing costs one subsystem request per navigation, which is a
    /// round trip on a connection that is already up.
    private func withSFTP<T>(_ work: (SFTPClient) async throws -> T) async throws -> T {
        let sftp: SFTPClient
        do {
            // Citadel's own logger, which is an `os.Logger`'s opposite: this module logs through
            // `os`, and the SFTP client's chatter is left on whatever the app bootstrapped rather
            // than pulling swift-log in here for it.
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

    /// Settles what a symbolic link points at, for the rows that are links.
    ///
    /// A tap on a row is asking "does this open", and for a link the listing's own attributes do
    /// not answer it: SFTP describes the link rather than its target, so a link to a folder would
    /// be a row that tries to preview a folder. Each link gets a second look — the same second
    /// look the Mac's browser takes, where `fileExists` follows the link and only links pay for
    /// it.
    ///
    /// All at once, because a folder of links is a folder of round trips: `/usr/bin` is a
    /// thousand of them, and one after another that is a minute of spinner on a real connection.
    /// A link whose target cannot be reached is left reading as a file, which is the honest
    /// answer for a broken one: a tap that fails beats a tap that opens nothing.
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

    /// Runs one command on the server and hands back its output.
    ///
    /// `executeCommand` fails the call on a non-zero exit status *and* on anything at all written
    /// to stderr, so a folder the server will not read arrives here as an error rather than as a
    /// short listing — which is the answer the browser wants anyway, since a truncated list of a
    /// folder you cannot read is worse than being told you cannot read it. What the server put on
    /// stderr is the sentence the user is shown, because it is the only thing that knows *why*.
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

    /// Bounds, all four of them the same numbers the Mac's own browser uses.
    ///
    /// The listing cap is not the one that binds while the `head` in the command holds — it is
    /// here so that the limit on what this end buffers is a decision this end made rather than one
    /// it inherits from whatever the server decided to send.
    private static let maximumListingBytes = 4 * 1024 * 1024
    private static let maximumPreviewBytes = 128 * 1024
    private static let previewChunkBytes = 32 * 1024
    private static let binaryProbeBytes = 8 * 1024

    /// What to tell the phone when something on the far end says no.
    ///
    /// The two SFTP statuses worth spelling out are the ones with an answer the user can act on:
    /// a folder that has gone, and one they are not allowed to open. Everything else falls back to
    /// the server's own words, which are at least true.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case is SFTPUnavailable:
            // A listing never reaches here — a session that will not open is what makes it fall
            // back to a command. A preview does, because it has nothing to fall back to: this is
            // the sentence for a server that stopped offering SFTP between the listing that
            // showed the file and the read that was asked for it.
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
