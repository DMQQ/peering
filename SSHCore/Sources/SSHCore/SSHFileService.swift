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
/// ``SSHFileService/text(_:kind:path:totalBytes:isTruncated:)``.
public struct SSHFileContents: Sendable, Equatable {
    public let path: String
    public let data: Data
    /// What these bytes are, decided by the server's bytes rather than by the name they arrived
    /// under — see ``RemoteFileKind/sniff(prefix:path:)``.
    ///
    /// Defaulted, because only one of the two doors that make this value is asking the question.
    /// A read has to answer it and does. A write is answering with the bytes the caller just sent,
    /// so the caller already knows, and the answer it gets back is about the size rather than the
    /// kind.
    public let kind: RemoteFileKind
    public let totalBytes: Int
    /// Whether these bytes are the whole file or only the front of it.
    ///
    /// **This is the difference between showing a file and destroying one.** The read stops at a cap,
    /// so a long file arrives cut short — which is the right thing to draw and a catastrophic thing
    /// to write back, because saving it would replace the file with its own first 128 KB and leave
    /// nothing at all behind to say that the rest had been lost.
    ///
    /// Carried on the value rather than recomputed by whoever needs it, so that the editor and the
    /// writer cannot arrive at different answers to the same question. Same shape and same reasoning
    /// as ``SSHDirectory/isTruncated``.
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
        /// Replace the file at `path` with `contents`.
        ///
        /// **The whole file, not a patch.** SFTP has no "change these bytes": the file is opened,
        /// truncated and written from zero. So a caller that hands over less than the file held
        /// destroys the difference, silently and irreversibly — which is why
        /// ``SSHFileContents/isTruncated`` travels with every read and why the editor refuses to
        /// open a file whose bytes are not all of it.
        ///
        /// The bytes are `Data` rather than `String` because the same door carries an upload, and
        /// an upload is whatever the user picked: a script, an archive, a PDF.
        case write(contents: Data)
        /// Something made, renamed or removed. See ``RemoteFileOperation`` for the three and for
        /// why they travel as one.
        case change(RemoteFileOperation)
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
    /// What is on the server *now*, after a write — read back as the answer rather than assumed.
    ///
    /// Returned as contents rather than as a bare success so the editor learns the file's real size
    /// and its own bytes as the server holds them. A save that echoed only "done" would leave the
    /// screen showing text nobody had confirmed, and a file that came back different — truncated by
    /// a quota, re-encoded by something in between — would look saved.
    case written(SSHFileContents)
    /// What the server did, in a sentence the caller can put in the log.
    ///
    /// Composed here rather than on the phone for the reason the Mac's is: this is the side that
    /// watched it happen, and for a recursive delete it is the only side that knows how much went.
    /// There is no contents to hand back — the caller re-lists the folder, which is the same move
    /// an upload already makes and for the same reason: asking again is cheaper to get right than
    /// patching one entry into a list that may have moved on in other ways too.
    case changed(note: String)
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

            let file = try await sftp.openFile(filePath: path, flags: .read)
            var data = Data()
            var kind = RemoteFileKind.text
            var limit = Self.maximumPreviewBytes

            /// Reads until the cap or the end of the file.
            ///
            /// A read is allowed to return less than it was asked for, so it is asked again. The
            /// Mac's own reader loops for the same reason: for a regular file it never does, and
            /// the loop costs one comparison. A local function rather than one loop, because this
            /// now runs twice — see below.
            func read(upTo cap: Int) async throws {
                while data.count < cap {
                    let length = UInt32(min(cap - data.count, Self.previewChunkBytes))
                    let piece = try await file.read(from: UInt64(data.count), length: length)
                    guard piece.readableBytes > 0 else { break }
                    data.append(contentsOf: piece.readableBytesView)
                }
            }

            do {
                // Twice, because the first pass decides the size of the second: what the head of
                // the file turns out to be is what says how much of the rest is worth carrying.
                // The Mac's reader is split the same way.
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
            // Whether the read stopped because the file ended or because the cap did.
            //
            // The second is the case that must never be written back, and a server that reported no
            // size counts as the second once the cap is reached: "might be truncated" and "is
            // truncated" lead to the same refusal, and guessing the other way loses somebody's file.
            let truncated = data.count >= limit
                && (attributes.size == nil || totalBytes > data.count)

            // A raster image is bytes, and goes exactly as it was read. Text and SVG are both text
            // on the wire, and text has one more thing to answer first — see
            // ``text(_:kind:path:totalBytes:isTruncated:)``. Checked after the handle is shut
            // rather than before it, so a file that turns out not to be showable has still been
            // closed exactly once on the way out.
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

    /// Replaces a file with the bytes given, over SFTP.
    ///
    /// **SFTP only, and that is not a limitation to be worked around.** The fallback provider is a
    /// one-off `ls` command, and a server that refuses a session the SFTP subsystem is not one to be
    /// sent file contents through a shell — escaping, quoting and a here-document would all have to
    /// be right, and every one of them is a way to write something other than what the user meant.
    /// Refused with a sentence instead.
    ///
    /// The open is `write | create | truncate`, which is exactly the whole-file replacement this
    /// promises and nothing more. A file that already exists keeps its mode: `create` only creates
    /// one that is not there, and truncating does not touch permissions — so saving a script leaves
    /// it executable, which is the difference between an edit and a broken deploy.
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
                // `SFTPFile.write` splits this into the 32 KB pieces the SFTP implementation wants,
                // so the whole buffer may be handed over at once. It is a loop internally, which is
                // why a large upload does not need one here.
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

    /// Something made, renamed or removed, over SFTP.
    ///
    /// **SFTP only, for the reason a write is.** The fallback provider is a one-off `ls` command,
    /// and changing a server's filesystem through a shell would mean quoting, here-documents and
    /// an `rm` assembled out of a name that arrived over a network — a different way to delete
    /// the wrong thing on every line. Refused with a sentence instead.
    private func change(_ operation: RemoteFileOperation) async throws -> String {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so files cannot be changed here."
            )
        }

        // Read before the session opens rather than inside the closure, because the closure is not
        // isolated and `start` is state this instance owns.
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

    /// An empty file, or a folder.
    ///
    /// The name is checked here as well as on the phone — ``RemoteFileName/isValid(_:)`` — and the
    /// check is what stops a rename or a creation becoming a *move*: a name holding a slash would
    /// otherwise name something in another folder, or above this one, and the panel offering it
    /// believes it is naming one thing inside the folder on screen.
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
            // `forceCreate` is `SSH_FXF_EXCL`, despite the name: it fails when the file is already
            // there, which is what makes this report a taken name as a taken name rather than
            // silently truncating somebody else's file to nothing. Closed immediately, because the
            // point is the entry and not the handle.
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .forceCreate]
            )
            try await file.close()
            return "created file \(name)"
        }
    }

    /// A new name for something already on the server.
    ///
    /// **The destination is checked before the rename, and the check is not a formality.** SFTP v3
    /// has no "do not overwrite" flag and its `rename` follows POSIX, which replaces the
    /// destination — so a rename onto a name that is taken destroys a file the user never picked.
    /// The pre-check turns that into a refusal, and what is left is the race: a file created
    /// between the check and the rename still goes. Closing it entirely would need an extension
    /// not every server implements, and the alternative — letting `rename` through unguarded —
    /// loses data every time rather than in a window measured in milliseconds.
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

    /// A file, or a folder and everything inside it.
    ///
    /// **The walk happens first and the deleting second, and that ordering is the whole of the
    /// safety here.** A folder cannot be `rmdir`'d until it is empty, so a recursive delete is
    /// necessarily a list of things followed by a list of removals — and collecting the whole list
    /// before removing anything means the two failure modes are "nothing happened" and "it worked"
    /// rather than "half the tree is gone and the connection dropped". It is also what makes the
    /// cap meaningful: a folder too large to walk is refused while it is still intact.
    ///
    /// **A symbolic link is a name, not a door.** Each entry's type comes from its parent's
    /// listing, which describes the entry itself — `getAttributes` is `SSH_FXP_STAT` and follows
    /// the link, so asking about a link that way would answer about whatever it points at. A link
    /// is removed as a link and never descended into, which is the difference between deleting a
    /// shortcut and deleting the folder it was pointing at.
    private static func delete(
        at path: String,
        start: String?,
        over sftp: SFTPClient
    ) async throws -> String {
        let name = (path as NSString).lastPathComponent
        // Guard rails against a bug rather than against a user: the browser draws a row per entry,
        // so nothing in the app offers to delete the folder a login starts in or anything above
        // it — you delete a row, not the folder you are standing in.
        //
        // **Containment and not equality**, for the reason the Mac's own guard gives: with the
        // login directory at `/home/dmq`, equality alone would leave `/home` — every account on
        // the server — as a legal thing to delete. The check is `pathContains(start, path)`, which
        // asks whether the *target* is an ancestor of where the session started, and so covers the
        // start directory, everything above it and the root without naming any of them.
        //
        // Nothing at all is covered when the start is not yet known, which is why the root is
        // refused on its own as well: a server whose listing never resolved would otherwise have
        // no guard at all, and `rmdir /` is not something to learn from a server's logs.
        guard path != "/", !(start.map { pathContains($0, path) } ?? false) else {
            throw SSHSessionError.browse("That is too much of the server to delete.")
        }
        guard let root = try? await sftp.getAttributes(at: path) else {
            throw SSHSessionError.browse("That is no longer there.")
        }
        // A file, or a link to anything at all: one `remove`, and no walking. This is also the
        // branch that keeps a link's target out of it.
        guard root.permissions.map({ $0 & 0o170_000 == 0o040_000 }) == true else {
            try await sftp.remove(at: path)
            return "deleted \(name)"
        }

        // Each entry carries what it is, decided in the walk, because the walk is the only place
        // that can answer it safely: a second look at removal time would be `getAttributes`, which
        // follows a link — so a link recorded as "not a folder" here could come back as one there
        // and be `rmdir`'d as though it were a folder of its own.
        var doomed: [(path: String, isFolder: Bool)] = []
        var pending = [path]
        var count = 0

        while let folder = pending.popLast() {
            let listed = try await sftp.listDirectory(atPath: folder)
            for component in listed.flatMap(\.components) {
                let entry = component.filename
                guard entry != ".", entry != ".." else { continue }
                count += 1
                // Refused rather than truncated: half a delete is the one outcome this whole
                // function is arranged to avoid, and a cap that trimmed the list would produce
                // exactly that — every entry removed, then an `rmdir` the server refuses.
                //
                // The number is a time bound as much as a size one. This runs on the command loop
                // the shell's keystrokes share, and SFTP is a round trip per entry, so the cap is
                // what keeps a delete from making the terminal stop answering for minutes.
                guard count <= maximumDeleteEntries else {
                    throw SSHSessionError.browse(
                        "That folder has more in it than this app will delete in one go (\(maximumDeleteEntries) entries). Delete it on the server instead."
                    )
                }

                let child = folder.hasSuffix("/") ? folder + entry : folder + "/" + entry
                // The type bits are the entry's own, which is the entire reason this reads them
                // from the parent's listing rather than asking the server about the entry: a link
                // is a file here, however its target would be classified.
                let isFolder = (component.attributes.permissions ?? 0) & 0o170_000 == 0o040_000
                doomed.append((child, isFolder))
                // Descended into only when it is a real folder. A link to a folder is a name that
                // points, and walking through it would delete the tree on the other side.
                if isFolder { pending.append(child) }
            }
        }

        // Reversed, and that is what makes this a post-order delete without a recursion: a folder
        // is always appended before anything inside it, so walking the list backwards removes every
        // child before its parent and each `rmdir` finds a folder that is already empty.
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

    /// How many entries one delete will take out.
    ///
    /// A thousand, and the figure is about the connection rather than the disk: this is answered
    /// inline on the loop that every keystroke goes through, and each entry is a round trip — so
    /// ten thousand files is a terminal that has stopped responding for minutes. Past the cap the
    /// answer is a refusal and a sentence saying to do it on the server, which is honest and
    /// costs the user one other tool for a folder they were unlikely to be deleting from a phone.
    private static let maximumDeleteEntries = 1_000

    /// The bytes of a preview, checked the way the Mac's own reader checks them.
    ///
    /// One refusal and one trim, both of them the host's rules rather than new ones: a buffer that
    /// does not decode is not text, and up to three bytes come off the end first, for the case
    /// where the read stopped at the cap rather than at the end of the file and the cut landed
    /// inside a character. Calling a text file binary because it was a long one is exactly the
    /// wrong answer.
    ///
    /// The NUL check that used to be the first of the two refusals has moved into
    /// ``RemoteFileKind/sniff(prefix:path:)``, and is not repeated here. That is not a relaxation:
    /// the sniffer runs on the same first eight kilobytes before this is reached, and a file with a
    /// NUL in that window never gets this far. What is left for this function is the question the
    /// sniffer cannot answer from a prefix, which is whether the *whole* read decodes.
    ///
    /// `kind` is carried through rather than decided here, because it was decided from the bytes
    /// and this only ever sees text and SVG.
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
    /// How much of a picture is fetched, rather than how much text.
    ///
    /// Sixty-four times the text cap, for the reason the Mac's own reader gives: a hundred
    /// kilobytes of text is two thousand lines, and a hundred kilobytes of photograph is a
    /// thumbnail. A preview that stops partway through a JPEG is not a smaller picture, it is no
    /// picture. Over a WAN this is the one transfer here that is worth a wait, and it is a wait the
    /// user asked for by opening the file.
    private static let maximumImagePreviewBytes = 8 * 1024 * 1024
    private static let previewChunkBytes = 32 * 1024
    private static let binaryProbeBytes = RemoteFileKind.probeBytes

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
