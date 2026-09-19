import Darwin
import Foundation
import RemoteCore
import os

private let terminalLog = Logger(subsystem: "pl.dmq.peering.host", category: "terminal")

/// Owns login shells independently of network connections. A disconnected phone can list the
/// sessions later and receives the bounded output history before live output resumes.
final class TerminalSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (TerminalEvent) -> Void

    private final class Session: @unchecked Sendable {
        let id: UUID
        let ownerClientID: String
        /// The name the tab shows. Resolved from the two below rather than set directly, so
        /// there is one place that decides which of them wins.
        var name: String
        let process: Process
        let master: FileHandle
        var isRunning = true
        var history = Data()
        var promptTail = ""
        var lastAttention: (kind: TerminalAttentionKind, time: Date)?
        /// The name the user typed. While this is set, nothing else renames the terminal.
        var manualName: String?
        /// The last command sent to it, which is what an unnamed terminal is called.
        var lastCommand: String?

        init(id: UUID, ownerClientID: String, name: String, process: Process, master: FileHandle) {
            self.id = id
            self.ownerClientID = ownerClientID
            self.name = name
            self.process = process
            self.master = master
        }

        var info: TerminalSessionInfo {
            TerminalSessionInfo(id: id, name: name, isRunning: isRunning)
        }
    }

    /// A file being written, between the request that opened it and the piece that closes it.
    ///
    /// Held whole in memory rather than streamed into place, and that is the decision this type
    /// exists to record: the write lands in one move or it does not land at all. A file written
    /// piece by piece as it arrives is a file that is half the old contents and half the new for as
    /// long as the transfer takes, and is the new contents only if nothing goes wrong, which is a
    /// state nothing on this machine can be in, since the thing being replaced is somebody's script.
    private final class PendingWrite: @unchecked Sendable {
        let ownerClientID: String
        let path: String
        /// What the client said it was sending. The last piece is refused unless this many bytes
        /// arrived, so a transfer that stopped early is a failed write rather than a short file.
        let expected: Int
        var data = Data()

        init(ownerClientID: String, path: String, expected: Int) {
            self.ownerClientID = ownerClientID
            self.path = path
            self.expected = expected
        }
    }

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var sinks: [String: Sink] = [:]
    private var writes: [WriteKey: PendingWrite] = [:]
    private static let maximumHistoryBytes = 512 * 1024
    private static let maximumSessionsPerClient = 10

    /// One terminal's write to one path.
    ///
    /// Keyed by both rather than by the path alone, because two phones watching the same Mac are
    /// two people, and one of them uploading into a folder must not disturb the other's transfer.
    /// And keyed by the terminal as well as the client, so that closing a shell can abandon exactly
    /// the transfers that were being made through it and not the ones through the shell beside it.
    ///
    /// Keyed by the path rather than by an identifier carried on the wire, because the interesting
    /// collision is one terminal beginning the same file twice, a user picking a second file, or
    /// the same one again, which has only one sensible answer: the newer attempt is the one they
    /// want, and the older is abandoned.
    private struct WriteKey: Hashable {
        let sessionID: UUID
        let path: String
    }

    /// How large a file this Mac will take from a phone.
    ///
    /// The same sixty-four megabytes the phone refuses to send, arrived at from the other end: the
    /// client's is about its own memory, and this one is about not letting a device that has been
    /// trusted with a login shell fill this machine's memory with a file it was never going to
    /// accept. Declared anyway, because a limit that only one end enforces is a limit that holds
    /// until the day the other end is older.
    private static let maximumWriteBytes = 64 * 1_048_576
    /// How much of a file may travel in one message.
    ///
    /// The mirror of ``previewChunkBytes``, and the number is the same because the constraint is:
    /// a `Data` on this channel is base64 in JSON, so thirty-two kilobytes of file is some
    /// forty-three of payload against a ``ProtocolInfo/maxControlPayload`` of sixty-four. Refused
    /// rather than trimmed. See ``write(id:path:data:isLast:ownerClientID:sink:)``.
    private static let writeChunkBytes = 32 * 1024

    /// How many entries one listing carries. A folder with more than this is a folder whose next
    /// screenful is worth fetching rather than one to send whole: the listing crosses the same
    /// connection as the shell's output, and a directory like `/usr/bin` is several thousand rows
    /// the user is going to scroll past. The answer says it was cut, so the client can say so too.
    private static let maximumDirectoryEntries = 2_000
    /// How much of a file a preview shows.
    ///
    /// Picked against the screen rather than against the file: the phone draws what it is sent as
    /// one piece of text, so this is also the most text it has to lay out, and a hundred kilobytes
    /// is some two thousand lines — more of a file than anyone scrolls on a phone and little
    /// enough that a preview is never a wait. A longer file is shown from the beginning and said
    /// to be, rather than refused.
    private static let maximumPreviewBytes = 128 * 1024
    /// How much of a file travels per event. Comfortably inside the 64 KB the control channel
    /// accepts for a request, and small enough that a preview never sits in front of a keystroke
    /// for long — see ``TerminalEvent/fileContents(sessionID:path:offset:totalBytes:data:isLast:)``.
    private static let previewChunkBytes = 32 * 1024
    /// How much of a file is looked at to decide whether it is text at all.
    private static let binaryProbeBytes = 8 * 1024

    deinit {
        let active = lock.withLock { Array(sessions.values) }
        for session in active where session.isRunning { session.process.terminate() }
    }

    func handle(clientID: String, request: TerminalRequest, sink: @escaping Sink) {
        guard !clientID.isEmpty else {
            sink(.failed(sessionID: nil, message: "The authenticated device has no identity."))
            return
        }
        lock.withLock { sinks[clientID] = sink }

        switch request {
        case .list:
            let snapshot = lock.withLock {
                sessions.values.filter { $0.ownerClientID == clientID }.map(\.info).sorted { $0.name < $1.name }
            }
            sink(.snapshot(snapshot))
            for info in snapshot {
                let history = lock.withLock {
                    sessions[info.id]?.ownerClientID == clientID ? sessions[info.id]?.history ?? Data() : Data()
                }
                if !history.isEmpty { sink(.output(sessionID: info.id, data: history)) }
            }

        case .create:
            let count = lock.withLock { sessions.values.filter { $0.ownerClientID == clientID }.count }
            guard count < Self.maximumSessionsPerClient else {
                sink(.failed(sessionID: nil, message: "Terminal session limit reached."))
                return
            }
            create(ownerClientID: clientID, sink: sink)

        case .rename(let id, let name):
            rename(id: id, ownerClientID: clientID, to: name, isManual: true)

        case .retitle(let id, let command):
            rename(id: id, ownerClientID: clientID, to: command, isManual: false)

        case .input(let id, let data):
            guard data.count <= 64 * 1024 else {
                sink(.failed(sessionID: id, message: "Terminal input was too large."))
                return
            }
            guard let session = liveSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            do { try session.master.write(contentsOf: data) }
            catch { sink(.failed(sessionID: id, message: "Could not write to the terminal.")) }

        case .listDirectory(let id, let path):
            guard liveSession(id, ownerClientID: clientID) != nil else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            list(id: id, requested: path, sink: sink)

        case .readFile(let id, let path):
            guard liveSession(id, ownerClientID: clientID) != nil else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            read(id: id, path: path, sink: sink)

        case .beginWrite(let id, let path, let totalBytes):
            guard liveSession(id, ownerClientID: clientID) != nil else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            beginWrite(id: id, path: path, totalBytes: totalBytes, ownerClientID: clientID, sink: sink)

        case .writeChunk(let id, let path, let data, let isLast):
            guard liveSession(id, ownerClientID: clientID) != nil else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            write(
                id: id,
                path: path,
                data: data,
                isLast: isLast,
                ownerClientID: clientID,
                sink: sink
            )

        case .resize(let id, let columns, let rows):
            guard columns > 0, rows > 0,
                  let session = lock.withLock({ sessions[id] }),
                  session.ownerClientID == clientID else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            if ioctl(session.master.fileDescriptor, TIOCSWINSZ, &size) == -1 {
                terminalLog.error("could not resize terminal \(id.uuidString, privacy: .public)")
            }

        case .close(let id):
            close(id: id, ownerClientID: clientID)
        }
    }

    /// A terminal this client owns and can still type into.
    ///
    /// The identifier arrives from the network, so every request that touches a shell asks this
    /// first: without it an authenticated client could name a terminal belonging to another
    /// device, and a terminal that has ended has no shell left to act on.
    private func liveSession(_ id: UUID, ownerClientID: String) -> Session? {
        lock.withLock {
            guard let session = sessions[id],
                  session.ownerClientID == ownerClientID,
                  session.isRunning else { return nil }
            return session
        }
    }

    func disconnect(clientID: String) {
        _ = lock.withLock {
            // Whatever it was in the middle of writing goes with it. The bytes are in this
            // process's memory and nowhere else, so an unfinished transfer is not a file waiting
            // to be resumed; it is a file that was never opened, and holding the pieces would be
            // holding them for a client that cannot come back and claim them.
            writes = writes.filter { $0.value.ownerClientID != clientID }
            return sinks.removeValue(forKey: clientID)
        }
    }

    private func create(ownerClientID: String, sink: @escaping Sink) {
        let id = UUID()
        let name = lock.withLock { unusedTerminalName() }
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var size = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            sink(.failed(sessionID: nil, message: "Could not create a terminal."))
            return
        }

        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let process = Process()
        // Foundation's Process can attach the slave descriptors but does not make them the
        // child's controlling terminal. `script` performs the required forkpty/setsid/TIOCSCTTY
        // setup, so job control and password prompts behave like a real Terminal window.
        let shell = loginShell()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shell, "-l"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        process.environment = environment
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        let session = Session(id: id, ownerClientID: ownerClientID, name: name, process: process, master: master)
        process.terminationHandler = { [weak self, weak session] process in
            guard let self, let session else { return }
            self.didExit(session, status: process.terminationStatus)
        }
        master.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.received(data, from: session)
        }

        do {
            lock.withLock { sessions[id] = session }
            try process.run()
            // The spawned process owns duplicated slave descriptors. Keeping the parent's copy
            // open would prevent EOF on the master after the shell exits.
            try? slave.close()
            sink(.created(session.info))
            terminalLog.notice("started terminal \(name, privacy: .public) \(id.uuidString, privacy: .public)")
        } catch {
            _ = lock.withLock { sessions.removeValue(forKey: id) }
            master.readabilityHandler = nil
            try? master.close()
            try? slave.close()
            sink(.failed(sessionID: id, message: "Could not start the login shell: \(error.localizedDescription)"))
        }
    }

    private func received(_ data: Data, from session: Session) {
        let attention: TerminalAttentionKind? = lock.withLock {
            guard sessions[session.id] === session else { return nil }
            session.history.append(data)
            if session.history.count > Self.maximumHistoryBytes {
                session.history.removeFirst(session.history.count - Self.maximumHistoryBytes)
            }
            let text = String(decoding: data, as: UTF8.self)
            session.promptTail = String((session.promptTail + text).suffix(1_024))
            guard let kind = Self.detectAttention(in: session.promptTail) else { return nil }
            if let last = session.lastAttention, last.kind == kind,
               Date().timeIntervalSince(last.time) < 5 { return nil }
            session.lastAttention = (kind, Date())
            return kind
        }

        send(.output(sessionID: session.id, data: data), to: session.ownerClientID)
        if let attention {
            let noun = attention == .password ? "a password" : "confirmation"
            send(.attention(
                sessionID: session.id,
                kind: attention,
                message: "Terminal “\(session.name)” is waiting for \(noun)."
            ), to: session.ownerClientID)
        }
    }

    private func didExit(_ session: Session, status: Int32) {
        session.master.readabilityHandler = nil
        lock.withLock {
            guard sessions[session.id] === session else { return }
            session.isRunning = false
        }
        send(.exited(sessionID: session.id, status: status), to: session.ownerClientID)
        terminalLog.notice("terminal \(session.id.uuidString, privacy: .public) exited with \(status)")
    }

    private func close(id: UUID, ownerClientID: String) {
        guard let session = lock.withLock({ () -> Session? in
            guard sessions[id]?.ownerClientID == ownerClientID else { return nil }
            return sessions.removeValue(forKey: id)
        }) else { return }
        session.master.readabilityHandler = nil
        if session.isRunning { session.process.terminate() }
        try? session.master.close()
        // A write made through this shell is a write that cannot be finished, because every piece
        // after this one is refused at the door for naming a terminal that is gone. Dropped here
        // rather than left to be refused one chunk at a time.
        lock.withLock { writes = writes.filter { $0.key.sessionID != id } }
        send(.closed(sessionID: id), to: ownerClientID)
        terminalLog.notice("closed terminal \(id.uuidString, privacy: .public)")
    }

    private func send(_ event: TerminalEvent, to clientID: String) {
        lock.withLock { sinks[clientID] }?(event)
    }

    // MARK: - Browsing

    private enum ListingOutcome {
        case entries([RemoteDirectoryEntry], truncated: Bool)
        case failure(String)
    }

    private enum PreviewOutcome {
        case contents(Data, totalBytes: Int)
        case failure(String)
    }

    /// One folder's contents.
    ///
    /// Answered off the connection's own queue. `contentsOfDirectory` is a blocking call, and on a
    /// network volume — or in a folder the system is about to put a consent prompt in front of —
    /// it takes as long as it takes. That queue carries every keystroke the phone sends, so the
    /// reading happens on another one and the answer comes back through the sink the shell's
    /// output already arrives on, which is a thread the caller has always been called from.
    private func list(id: UUID, requested: String?, sink: @escaping Sink) {
        // Absolute paths only. A relative one would resolve against this process's working
        // directory rather than against the shell's, which is the directory the user believes they
        // are looking at. Not an authorization boundary either way: whoever owns this terminal
        // already has a login shell as this user and can list any of it.
        //
        // Tested on the string that arrived, not on the `URL`: `URL(fileURLWithPath:)` quietly
        // makes a relative path absolute against the process's own working directory, so a check
        // after it would pass every time and mean nothing.
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.browseFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can open."
            ))
            return
        }
        // Standardised for the answer rather than for the lookup: `..` and doubled slashes come
        // out, so the path the phone puts in its breadcrumbs is the one it can send back. Symbolic
        // links are left alone, because a folder reached through one is the folder the user asked
        // for and the name they know it by.
        let directory = URL(fileURLWithPath: path).standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.entries(in: directory) {
            case .entries(let entries, let truncated):
                sink(.directory(
                    sessionID: id,
                    path: directory.path,
                    entries: entries,
                    truncated: truncated
                ))
            case .failure(let message):
                sink(.browseFailure(sessionID: id, path: directory.path, message: message))
            }
        }
    }

    /// A file's text, for the browser's preview.
    private func read(id: UUID, path: String, sink: @escaping Sink) {
        // Absolute, and tested on the string that arrived — see ``list(id:requested:sink:)``.
        guard path.hasPrefix("/") else {
            sink(.browseFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can open."
            ))
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.contents(of: url) {
            case .contents(let data, let totalBytes):
                Self.send(data, totalBytes: totalBytes, id: id, path: url.path, sink: sink)
            case .failure(let message):
                sink(.browseFailure(sessionID: id, path: url.path, message: message))
            }
        }
    }

    /// A file about to be written, and the three ways that is refused before any of it travels.
    ///
    /// Nothing on disk is touched here. The file is replaced by the last piece, so a transfer that
    /// never finishes leaves what was there exactly as it was, which is the whole reason this is
    /// two requests rather than the client naming a path and starting to send.
    ///
    /// Tested on the string that arrived, like the two above it, and for the reason given there:
    /// a relative path would resolve against this process's working directory rather than against
    /// the shell's, and there is no authorisation being done either way.
    private func beginWrite(
        id: UUID,
        path: String,
        totalBytes: Int,
        ownerClientID: String,
        sink: @escaping Sink
    ) {
        guard path.hasPrefix("/") else {
            sink(.writeFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can write to."
            ))
            return
        }
        guard totalBytes >= 0, totalBytes <= Self.maximumWriteBytes else {
            sink(.writeFailure(
                sessionID: id,
                path: path,
                message: "That file is too large to send to this Mac (the limit is \(Self.maximumWriteBytes / 1_048_576) MB)."
            ))
            return
        }
        // Standardised but not resolved: the answer names the path the client sent, so that the
        // one it is holding when the write lands is the one it still holds. Following the link is
        // ``replace(at:with:)``'s job, and doing it here as well would mean two answers to which
        // file this is.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let key = WriteKey(sessionID: id, path: url.path)
        lock.withLock {
            writes[key] = PendingWrite(ownerClientID: ownerClientID, path: url.path, expected: totalBytes)
        }
    }

    /// A piece of a file being written, and on the last one, the write itself.
    ///
    /// Answered off the connection's own queue for the reason the listing is: this is disk work on
    /// a path that may be a network volume, and the queue it arrives on carries every keystroke the
    /// phone sends.
    private func write(
        id: UUID,
        path: String,
        data: Data,
        isLast: Bool,
        ownerClientID: String,
        sink: @escaping Sink
    ) {
        // Standardised the same way ``beginWrite(id:path:totalBytes:ownerClientID:sink:)`` did, or
        // a path written two ways would be two different keys and every piece would arrive for a
        // transfer nobody had opened.
        let key = WriteKey(sessionID: id, path: URL(fileURLWithPath: path).standardizedFileURL.path)
        // The size check is against the request as it will be encoded, not against the file: this
        // channel carries base64 in JSON, so a chunk that looks small is three-quarters again as
        // large by the time it is a payload, and a message over the cap is not a message the far
        // end can complain about; it takes the session down. Refused here, where there is still
        // somebody to tell.
        guard data.count <= Self.writeChunkBytes else {
            lock.withLock { _ = writes.removeValue(forKey: key) }
            sink(.writeFailure(
                sessionID: id,
                path: path,
                message: "That transfer was sent in pieces this Mac cannot accept."
            ))
            return
        }

        /// Three answers rather than two, because most pieces are neither the start nor the end of
        /// anything: a chunk that is not the last one is accepted and answered with silence, and a
        /// two-case result would have to spell that as a refusal with nothing in it.
        enum State {
            case more
            case ready(PendingWrite)
            case refused(String)
        }
        let state: State = lock.withLock {
            guard let pending = writes[key] else {
                return .refused("That file is no longer being written. Choose it again.")
            }
            // A client that sends more than it said it would is not a client to keep guessing
            // about: the declared size is the only thing that says when a file is whole, and a
            // transfer that has stopped agreeing with it has no correct end.
            guard pending.data.count + data.count <= pending.expected else {
                writes.removeValue(forKey: key)
                return .refused("That transfer sent more than it said it would.")
            }
            pending.data.append(data)
            guard isLast else { return .more }
            guard pending.data.count == pending.expected else {
                writes.removeValue(forKey: key)
                return .refused("That transfer stopped before the whole file arrived.")
            }
            writes.removeValue(forKey: key)
            return .ready(pending)
        }

        switch state {
        case .more:
            // Nothing is said, and saying nothing is the point: this is one of a few thousand
            // messages, and an acknowledgement each would double the traffic to report progress
            // that nothing on screen is showing.
            break
        case .refused(let message):
            sink(.writeFailure(sessionID: id, path: path, message: message))
        case .ready(let pending):
            let url = URL(fileURLWithPath: pending.path)
            DispatchQueue.global(qos: .userInitiated).async {
                // Answered with the path as it arrived rather than with the standardised one that
                // was written to. They are the same file, and they are not always the same string:
                // the client is holding the one it sent, and an answer it cannot match to it is an
                // answer that leaves an editor spinning.
                switch Self.replace(at: url, with: pending.data) {
                case .written(let totalBytes):
                    sink(.wroteFile(sessionID: id, path: path, totalBytes: totalBytes))
                case .failure(let message):
                    sink(.writeFailure(sessionID: id, path: path, message: message))
                }
            }
        }
    }

    private enum WriteOutcome {
        case written(Int)
        case failure(String)
    }

    /// Puts the bytes where the file was, or says why it could not.
    ///
    /// **The mode is read first and put back afterwards, and it has to be.** An atomic write lands
    /// a new file and renames it over the old one, so the permissions that arrive with it are the
    /// temporary file's rather than the ones the file had, and a shell script saved through this
    /// browser would come back not executable. That is a change to somebody's file that nothing on
    /// the phone asked for and nothing on the screen would have said.
    ///
    /// **And the link is followed before any of that.** Read this way round because the browser
    /// reads the same way: a symbolic link to a text file is a text file to anyone looking at it,
    /// and a write that landed on the link itself would replace somebody's link with a copy of
    /// their file, which is a worse outcome than the edit not working.
    private static func replace(at url: URL, with data: Data) -> WriteOutcome {
        let target = url.resolvingSymlinksInPath()
        let existing = try? FileManager.default.attributesOfItem(atPath: target.path)

        if let existing, existing[.type] as? FileAttributeType == .typeDirectory {
            return .failure("That is a folder, so a file cannot be written over it.")
        }

        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return .failure(writeMessage(for: error))
        }

        if let mode = existing?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        return .written(data.count)
    }

    /// What to tell the phone when the filesystem refuses a write.
    ///
    /// Its own function rather than a share of ``browseMessage(for:)``, because the failures worth
    /// naming are not the same ones: reading a folder is refused by Files and Folders, and writing
    /// into one is refused by that *and* by the file being somebody else's, which is the case the
    /// sentence below has to cover without pretending to know which it was.
    private static func writeMessage(for error: any Error) -> String {
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
            case EPERM, EACCES: return writeMessage(for: NSError(
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

    /// A preview, in pieces.
    ///
    /// A chunk boundary can fall inside a UTF-8 character — the cut is by bytes and the text is
    /// not — so the client joins the pieces before decoding them. The last piece says it is the
    /// last, and `totalBytes` is what tells a whole file from the beginning of one.
    private static func send(_ data: Data, totalBytes: Int, id: UUID, path: String, sink: Sink) {
        guard !data.isEmpty else {
            sink(.fileContents(
                sessionID: id,
                path: path,
                offset: 0,
                totalBytes: totalBytes,
                data: Data(),
                isLast: true
            ))
            return
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.previewChunkBytes, data.count)
            sink(.fileContents(
                sessionID: id,
                path: path,
                offset: offset,
                totalBytes: totalBytes,
                data: data.subdata(in: offset..<end),
                isLast: end == data.count
            ))
            offset = end
        }
    }

    /// No size among them: `URLResourceValues` has no key for the mode bits, so the two come from
    /// one `attributesOfItem` instead — and it is the call that has to be used anyway, because
    /// `fileSize` answers nothing at all for a folder, which is a row that now has a size.
    private static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]

    private static func entries(in directory: URL) -> ListingOutcome {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(entryKeys),
                // Hidden entries are listed rather than skipped. Which of them to show is the
                // phone's decision, and a filter here would be a second answer to a question the
                // client already answers — including for the SSH browser this will serve next,
                // which has its own idea of what "hidden" means.
                options: []
            )
        } catch {
            return .failure(browseMessage(for: error))
        }

        // Entered as it will be read: folders first, then by name. Sorted here rather than on the
        // phone so every client shows the same order without having to agree on how two names
        // compare, and compared the way the Finder compares them, so `file 10` follows `file 9`
        // rather than `file 1`.
        let entries = urls.compactMap(entry(for:)).sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
        // Cut after the sort, so what arrives is the beginning of a real order rather than
        // whatever order the filesystem happened to hand over.
        return .entries(
            Array(entries.prefix(Self.maximumDirectoryEntries)),
            truncated: entries.count > Self.maximumDirectoryEntries
        )
    }

    /// One row, or nothing for an entry that could not be described.
    ///
    /// Dropped rather than fatal: a file deleted between the listing and the look is a row missing
    /// from a folder, not a folder that failed to open.
    private static func entry(for url: URL) -> RemoteDirectoryEntry? {
        guard let values = try? url.resourceValues(forKeys: entryKeys) else { return nil }

        let isSymlink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false
        if isSymlink {
            // A link reports its own type rather than its target's, and a link to a folder is a
            // folder as far as a tap on the row is concerned. `fileExists` follows the link, which
            // is exactly the question being asked there, and only links pay for the second look.
            var pointsAtDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &pointsAtDirectory) {
                isDirectory = pointsAtDirectory.boolValue
            }
        }

        // One look for the mode bits *and* the size, which is the pair `ls -l` prints a row of.
        // A folder included: the number beside one there is the bytes its own entry takes, and
        // that is what this browser is the picture of.
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

    /// The mode bits in the form `ls -l` prints them, type character and all.
    ///
    /// The one field here with no resource-value key of its own, so it comes from the call that
    /// has answered this question since before `URL` did — the same call ``entry(for:)`` takes
    /// the size from, which is why the attributes arrive rather than a path.
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
        // The three that sit on top of an execute bit and are printed in its place: `s` where the
        // execute bit is set too and `S` where it is not, and the same idea with `t` and `T` for
        // the sticky bit.
        var characters = Array(bits)
        if mode & 0o4000 != 0 { characters[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { characters[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { characters[8] = mode & 0o001 != 0 ? "t" : "T" }
        return type + String(characters)
    }

    /// A file's text, bounded.
    ///
    /// Four answers, and the refusals are each a thing the user would otherwise meet as a broken
    /// screen: something that is not a file, something that cannot be read, something that is not
    /// text, and something too long to show whole — the last of which is a beginning rather than a
    /// refusal.
    private static func contents(of url: URL) -> PreviewOutcome {
        // Through `stat` rather than a resource value, so the answer follows a symbolic link: a
        // link to a text file is a text file to anyone looking at it.
        var info = stat()
        var failure: Int32 = 0
        let looked = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else {
                failure = EINVAL
                return -1
            }
            let result = stat(pointer, &info)
            if result != 0 { failure = errno }
            return result
        }
        guard looked == 0 else { return .failure(message(forErrno: failure)) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .failure("That is not a file, so there is nothing to show here.")
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { return .failure(browseMessage(for: error)) }
        defer { try? handle.close() }

        let totalBytes = Int(info.st_size)
        let limit = min(totalBytes, Self.maximumPreviewBytes)
        var data = Data()
        do {
            // A read is allowed to return less than it was asked for, so it is asked again until
            // the cap or the end of the file. For a regular file it never does, and the loop costs
            // one comparison.
            while data.count < limit {
                guard let piece = try handle.read(upToCount: limit - data.count),
                      !piece.isEmpty else { break }
                data.append(piece)
            }
        } catch {
            return .failure(browseMessage(for: error))
        }

        // A NUL byte near the start is the same test `file` uses to call something binary, and the
        // one editors refuse to open a file on. Nothing here can render an image or a database,
        // and a screen of replacement characters is a worse answer than being told why.
        guard !data.prefix(Self.binaryProbeBytes).contains(0) else {
            return .failure("That file is not text, so there is nothing to show here.")
        }
        // And what got past that still has to decode. Up to three bytes come off the end first,
        // for the case where the read stopped at the cap rather than at the end of the file and
        // the cut landed inside a character: calling a text file binary because it was long is
        // exactly the wrong answer.
        var text = data
        var dropped = 0
        while dropped < 3, String(data: text, encoding: .utf8) == nil, !text.isEmpty {
            text = text.dropLast()
            dropped += 1
        }
        guard String(data: text, encoding: .utf8) != nil else {
            return .failure("That file is not text, so there is nothing to show here.")
        }
        return .contents(text, totalBytes: totalBytes)
    }

    /// What to tell the phone when the filesystem says no.
    ///
    /// The permission case is the one worth spelling out: it is the only failure here the user can
    /// do anything about, and the only one where the Mac has already asked them a question the
    /// phone never saw. macOS answers "operation not permitted" both when the prompt was declined
    /// and when it has not been shown yet, so the sentence names the setting rather than guessing
    /// which of the two it was.
    private static func message(forErrno code: Int32) -> String {
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

    private static func browseMessage(for error: any Error) -> String {
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

    /// Puts a new name on a terminal, if it will take one.
    ///
    /// Two kinds of name, and the difference between them is the whole of the naming rule. One
    /// the user typed, which sticks and is never replaced. And one the terminal earns by being
    /// used — the last command run in it — which holds only until the user names it by hand.
    ///
    /// Clearing the name is the way back. An empty field says "stop calling it that", and the
    /// terminal goes back to the last thing that ran there, or to a number if nothing has.
    private func rename(id: UUID, ownerClientID: String, to requested: String, isManual: Bool) {
        let updated: TerminalSessionInfo? = lock.withLock {
            guard let session = sessions[id], session.ownerClientID == ownerClientID else { return nil }
            let name = sanitizedName(requested)
            if isManual {
                session.manualName = name.isEmpty ? nil : name
            } else {
                // Remembered even while a hand-typed name is in force, so clearing that name
                // has something to fall back to.
                guard !name.isEmpty else { return nil }
                session.lastCommand = name
            }
            let resolved = session.manualName
                ?? session.lastCommand
                ?? unusedTerminalName(excluding: session)
            guard resolved != session.name else { return nil }
            session.name = resolved
            return session.info
        }
        guard let updated else { return }
        send(.renamed(updated), to: ownerClientID)
        terminalLog.notice("renamed terminal to \(updated.name, privacy: .public)")
    }

    /// The lowest "Terminal N" that no live terminal is using.
    ///
    /// Counted rather than taken from the count: close the second of three and open another,
    /// and counting hands out a second Terminal 2. That used to be a harmless collision and is
    /// not one now that the strip of tabs is the list of terminals.
    private func unusedTerminalName(excluding excluded: Session? = nil) -> String {
        let taken = Set(sessions.values.filter { $0 !== excluded }.map(\.name))
        var number = 1
        while taken.contains("Terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }

    /// A name with the control characters taken out and a length a tab can show.
    private func sanitizedName(_ requested: String) -> String {
        let safe = String(requested.filter { character in
            !character.isNewline && !character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        }.prefix(40))
        return safe.trimmingCharacters(in: .whitespaces)
    }

    private func loginShell() -> String {
        if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func detectAttention(in rawText: String) -> TerminalAttentionKind? {
        let plain = rawText.replacingOccurrences(
            of: "\\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        ).lowercased()
        let tail = String(plain.suffix(400))
        if tail.range(of: #"(?:password|passphrase)(?: for [^:\n]+)?:\s*$"#, options: .regularExpression) != nil {
            return .password
        }
        let confirmationPatterns = [
            #"(?:\[|\()(?:y/n|yes/no)(?:\]|\))\??\s*$"#,
            #"are you sure[^\n]*\??\s*$"#,
            #"press (?:enter|return)[^\n]*$"#,
            #"continue\?\s*$"#,
        ]
        return confirmationPatterns.contains {
            tail.range(of: $0, options: .regularExpression) != nil
        } ? .confirmation : nil
    }
}
