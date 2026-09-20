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
    /// **The write still lands in one move or it does not land at all**, which is the decision this
    /// type exists to record and which has not changed. A file written piece by piece *into place*
    /// is a file that is half the old contents and half the new for as long as the transfer takes,
    /// and is the new contents only if nothing goes wrong, which is a state nothing on this machine
    /// can be in, since the thing being replaced is somebody's script.
    ///
    /// **What changed is where the pieces wait.** They used to wait in this process's memory, which
    /// made the size limit a limit on the Mac's memory: the number was the most this machine was
    /// willing to spend on somebody else's file, and past it the honest answer was no. They now
    /// wait in a scratch file beside the destination, under a name nothing will look for, and the
    /// destination is still untouched until the last piece arrives and the scratch file is moved
    /// over it in one step. So a transfer costs a handle and a piece of a disk rather than the file
    /// itself, and the limit is free to be about the disk and the wait instead of about this
    /// process not being killed.
    private final class PendingWrite: @unchecked Sendable {
        let ownerClientID: String
        let path: String
        /// What the client said it was sending. The last piece is refused unless this many bytes
        /// arrived, so a transfer that stopped early is a failed write rather than a short file.
        let expected: Int
        /// The destination as the filesystem will see it. Resolved once when the transfer opens
        /// rather than at the move, because the scratch file has to be created in the same
        /// directory as the file it becomes: a rename across volumes is a copy, and a copy is not
        /// one step and can be left half done.
        let target: URL
        /// Where the pieces go while they arrive, under a name nothing will look for.
        let staging: URL
        /// Opened on the first piece rather than here, so that the request that opens a transfer
        /// does no disk work on the queue that carries every keystroke the phone sends.
        var handle: FileHandle?
        /// How many bytes have been appended. Touched only under the manager's lock.
        var received = 0
        /// The first thing that went wrong writing to disk, if anything did.
        ///
        /// Recorded rather than reported, because there may be thousands of pieces still to come
        /// and the user is owed one answer at the end rather than a sentence per piece. Once it is
        /// set, the pieces after it are dropped: a transfer with a hole in it is not a file.
        var failure: String?

        init(ownerClientID: String, path: String, expected: Int, target: URL, staging: URL) {
            self.ownerClientID = ownerClientID
            self.path = path
            self.expected = expected
            self.target = target
            self.staging = staging
        }

        /// Closes the handle and removes the scratch file, and is safe to call once.
        ///
        /// Called on the write queue rather than under the lock: closing a handle is a disk
        /// operation, and one of the callers is the teardown path that runs while the lock is
        /// held. The handle is taken rather than closed in place, so a second call has nothing to
        /// do.
        func discard() {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// The one queue every write's disk work happens on.
    ///
    /// **Not the connection's queue**, which carries every keystroke the phone sends: a piece
    /// appended there is a keystroke delayed by however long a path on a network volume takes to
    /// answer, and the same reason the final write was already moved off it.
    ///
    /// **One queue rather than one per transfer.** A disk is one device and two transfers
    /// interleaving on it gain nothing; what matters is that one transfer's pieces are appended in
    /// the order they arrived, and that is what a single serial queue gives, since they are
    /// enqueued in exactly that order.
    private static let writeIO = DispatchQueue(
        label: "pl.dmq.peering.host.write",
        qos: .userInitiated
    )

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
    /// **No longer a number about anybody's memory.** It used to be sixty-four megabytes on each
    /// end for the same shape of reason: the phone read the file into memory to send it, and this
    /// end collected the pieces in memory to write it, so the limit was the most either was willing
    /// to hold on somebody else's behalf. Both ends stream now, so what is left to bound is the
    /// disk the file lands on and the wait the user is in for, and neither of those is a figure
    /// anybody can pick for them.
    ///
    /// Two gigabytes, which covers the thing this limit is actually met by: a video clip. It is
    /// still a ceiling rather than no ceiling, because there is no way to stop a transfer once it
    /// has started and a mis-tap on a folder of raw footage should not commit somebody to an hour
    /// of it. Declared on both ends, because a limit that only one end enforces is a limit that
    /// holds until the day the other end is older.
    private static let maximumWriteBytes = 2 * 1_073_741_824
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
    /// How much of a *picture* a preview shows.
    ///
    /// Sixty-four times the text cap, and the reason is that the two are answering different
    /// questions. A hundred kilobytes of text is two thousand lines, more than anyone scrolls; a
    /// hundred kilobytes of photograph is a thumbnail, and a preview that stops a third of the way
    /// into a JPEG is not a smaller picture, it is no picture at all — there is nothing useful to
    /// draw from the first bytes of one. So the limit here is set by what a picture actually
    /// weighs: eight megabytes covers a phone photo and a screenshot with room to spare, and the
    /// refusal past it is said out loud rather than shown as a broken frame.
    private static let maximumImagePreviewBytes = 8 * 1024 * 1024
    /// How much of a file travels per event. Comfortably inside the 64 KB the control channel
    /// accepts for a request, and small enough that a preview never sits in front of a keystroke
    /// for long — see ``TerminalEvent/fileContents(sessionID:path:offset:totalBytes:data:isLast:)``.
    private static let previewChunkBytes = 32 * 1024
    /// How much of a file is looked at to decide whether it is text at all.
    private static let binaryProbeBytes = RemoteFileKind.probeBytes

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

        case .changeFile(let id, let operation):
            guard liveSession(id, ownerClientID: clientID) != nil else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            change(id: id, operation: operation, sink: sink)

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
        // Whatever it was in the middle of writing goes with it. An unfinished transfer is not a
        // file waiting to be resumed, because there is nothing to resume it with: the client that
        // cannot come back and claim it is the one that has just gone.
        let abandoned = lock.withLock { () -> [PendingWrite] in
            let mine = writes.values.filter { $0.ownerClientID == clientID }
            writes = writes.filter { $0.value.ownerClientID != clientID }
            _ = sinks.removeValue(forKey: clientID)
            return mine
        }
        // **And the pieces have to be deleted, where they used to simply stop existing.** They are
        // on somebody's disk now rather than in this process's memory, so a transfer cut short
        // leaves a scratch file beside its destination, and leaving those behind would fill a
        // folder with the ghosts of every upload that ever failed. On the write queue, so the
        // removal lands after any append still in flight for the same transfer and takes the last
        // of it rather than all but the piece that was being written.
        for pending in abandoned {
            Self.writeIO.async { pending.discard() }
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
        case contents(Data, kind: RemoteFileKind, totalBytes: Int)
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
            case .contents(let data, let kind, let totalBytes):
                Self.send(data, kind: kind, totalBytes: totalBytes, id: id, path: url.path, sink: sink)
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
                message: "That file is too large to send to this Mac (the limit is \(Self.maximumWriteBytes.formatted(.byteCount(style: .file))))."
            ))
            return
        }
        // Standardised but not resolved: the answer names the path the client sent, so that the
        // one it is holding when the write lands is the one it still holds. Following the link is
        // ``commit(_:to:)``'s job, and doing it here as well would mean two answers to which file
        // this is.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let key = WriteKey(sessionID: id, path: url.path)
        // Resolved here, once, rather than at the move. `resolvingSymlinksInPath` is a stat call
        // per component and this is the one moment it is affordable: the queue this runs on carries
        // every keystroke the phone sends. See ``PendingWrite/target``.
        let target = url.resolvingSymlinksInPath()
        // The scratch file's name is derived from the destination and hung off the front with a
        // dot, so it is hidden, sorts beside the file it will become, and cannot collide with it or
        // with a second transfer of the same file: a second transfer of the same path replaces this
        // record, and the first transfer's scratch file has to be a different name or the two are
        // appending into one file. Nothing looks for a name starting with a dot.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).peering-\(UUID().uuidString).part")
        lock.withLock {
            writes[key] = PendingWrite(
                ownerClientID: ownerClientID,
                path: url.path,
                expected: totalBytes,
                target: target,
                staging: staging
            )
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
            let abandoned = lock.withLock { writes.removeValue(forKey: key) }
            if let abandoned { Self.writeIO.async { abandoned.discard() } }
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
            case more(PendingWrite, Data)
            case ready(PendingWrite, Data)
            case refused(String)
        }
        let state: State = lock.withLock {
            guard let pending = writes[key] else {
                return .refused("That file is no longer being written. Choose it again.")
            }
            // A client that sends more than it said it would is not a client to keep guessing
            // about: the declared size is the only thing that says when a file is whole, and a
            // transfer that has stopped agreeing with it has no correct end.
            guard pending.received + data.count <= pending.expected else {
                writes.removeValue(forKey: key)
                return .refused("That transfer sent more than it said it would.")
            }
            pending.received += data.count
            guard isLast else { return .more(pending, data) }
            guard pending.received == pending.expected else {
                writes.removeValue(forKey: key)
                return .refused("That transfer stopped before the whole file arrived.")
            }
            writes.removeValue(forKey: key)
            return .ready(pending, data)
        }

        switch state {
        case .more(let pending, let piece):
            // **The accounting happens here and the bytes go to disk on their own queue.** The
            // order between the two is what makes this safe: the pieces are enqueued in the order
            // they arrived, on one serial queue, so whether the handle is opened by the first of
            // them or by the twentieth, the file they build is the same file.
            //
            // Nothing is said back, and saying nothing is the point: this is one of a few thousand
            // messages, and an acknowledgement each would double the traffic to report progress
            // that nothing on screen is showing.
            Self.writeIO.async { Self.append(piece, to: pending) }

        case .refused(let message):
            // Whatever was already appended is thrown away, and the destination was never touched.
            // A refusal from here can arrive after several thousand pieces have gone to disk, which
            // is exactly why the scratch file exists rather than the destination being written.
            if let abandoned = lock.withLock({ writes[key] }) {
                _ = lock.withLock { writes.removeValue(forKey: key) }
                Self.writeIO.async { abandoned.discard() }
            }
            sink(.writeFailure(sessionID: id, path: path, message: message))

        case .ready(let pending, let piece):
            // The last piece's append and the move that follows it are enqueued together, and the
            // queue is serial, so the move cannot overtake the bytes it is moving.
            Self.writeIO.async {
                Self.append(piece, to: pending)
                Self.finish(pending) { outcome in
                    // Answered with the path as it arrived rather than with the standardised one
                    // that was written to. They are the same file, and they are not always the same
                    // string: the client is holding the one it sent, and an answer it cannot match
                    // to it is an answer that leaves an editor spinning.
                    switch outcome {
                    case .written(let totalBytes):
                        sink(.wroteFile(sessionID: id, path: path, totalBytes: totalBytes))
                    case .failure(let message):
                        sink(.writeFailure(sessionID: id, path: path, message: message))
                    }
                }
            }
        }
    }

    /// Appends one piece to a transfer's scratch file, opening the file on the first piece.
    ///
    /// **Runs on ``writeIO`` and nowhere else**, so the lazy open needs no lock and no ordering
    /// care: the pieces are enqueued in the order they arrived, so the first call is the first
    /// piece, whether the client sent one byte or two gigabytes.
    ///
    /// A failure is recorded rather than reported. See ``PendingWrite/failure``.
    private static func append(_ piece: Data, to pending: PendingWrite) {
        guard pending.failure == nil else { return }

        if pending.handle == nil {
            do {
                // An empty write rather than `createFile`, because this form answers with *why* it
                // could not: a folder that is somebody else's, a volume with no room, and a
                // directory that has been deleted all look the same from a `Bool`.
                try Data().write(to: pending.staging)
                pending.handle = try FileHandle(forWritingTo: pending.staging)
            } catch {
                pending.failure = FileReplacement.message(for: error)
                try? FileManager.default.removeItem(at: pending.staging)
                return
            }
        }

        do {
            try pending.handle?.write(contentsOf: piece)
        } catch {
            pending.failure = FileReplacement.message(for: error)
        }
    }

    /// Closes a transfer's scratch file and moves it over the destination in one step.
    ///
    /// Runs on ``writeIO``, after the last piece has been appended by the same queue, so the move
    /// cannot overtake the bytes it is moving.
    private static func finish(_ pending: PendingWrite, then report: (FileReplacement.Outcome) -> Void) {
        if let failure = pending.failure {
            pending.discard()
            report(.failure(failure))
            return
        }
        try? pending.handle?.close()
        pending.handle = nil
        // The move itself lives in ``FileReplacement``, with tests, because it is a rule that is
        // wrong silently: a replacement that has quietly become a copy across volumes works
        // perfectly until the moment it does not.
        report(FileReplacement.commit(staging: pending.staging, to: pending.target))
    }

    /// A preview, in pieces.
    ///
    /// A chunk boundary can fall inside a UTF-8 character — the cut is by bytes and the text is
    /// not — so the client joins the pieces before decoding them. The last piece says it is the
    /// last, and `totalBytes` is what tells a whole file from the beginning of one.
    ///
    /// Every piece carries the kind, the same value each time, because the client's answer to
    /// "what am I holding" has to be there before the first piece is drawn and there is no piece
    /// marked as the one it should be read from.
    private static func send(
        _ data: Data,
        kind: RemoteFileKind,
        totalBytes: Int,
        id: UUID,
        path: String,
        sink: Sink
    ) {
        guard !data.isEmpty else {
            sink(.fileContents(
                sessionID: id,
                path: path,
                kind: kind,
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
                kind: kind,
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

    /// A file's contents, bounded: its text if it is text, and its bytes if it is a picture.
    ///
    /// Four answers, and the refusals are each a thing the user would otherwise meet as a broken
    /// screen: something that is not a file, something that cannot be read, something that is
    /// neither text nor a picture this can show, and something too long to show whole — the last
    /// of which is a beginning rather than a refusal.
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
        var data = Data()
        var kind = RemoteFileKind.text
        do {
            // A read is allowed to return less than it was asked for, so it is asked again until
            // the cap or the end of the file. For a regular file it never does, and the loop costs
            // one comparison.
            //
            // In two passes, because the first one decides the size of the second: what the head
            // of the file turns out to be is what says how much of the rest is worth carrying.
            let probe = min(totalBytes, Self.binaryProbeBytes)
            while data.count < probe {
                guard let piece = try handle.read(upToCount: probe - data.count),
                      !piece.isEmpty else { break }
                data.append(piece)
            }

            guard let sniffed = RemoteFileKind.sniff(prefix: data, path: url.path) else {
                return .failure(
                    "That file is not text or a picture, so there is nothing to show here."
                )
            }
            kind = sniffed

            let limit = min(
                totalBytes,
                kind.isDrawn ? Self.maximumImagePreviewBytes : Self.maximumPreviewBytes
            )
            while data.count < limit {
                guard let piece = try handle.read(upToCount: limit - data.count),
                      !piece.isEmpty else { break }
                data.append(piece)
            }
        } catch {
            return .failure(browseMessage(for: error))
        }

        // `isDrawn` set the cap above; this is a different question with a different answer. A
        // raster image is bytes, and goes exactly as it was read. Text and SVG are both text on
        // the wire, and text has one more thing to answer before it can be sent.
        if kind == .image { return .contents(data, kind: kind, totalBytes: totalBytes) }

        // It has to decode. Up to three bytes come off the end first, for the case where the read
        // stopped at the cap rather than at the end of the file and the cut landed inside a
        // character: calling a text file binary because it was long is exactly the wrong answer.
        var text = data
        var dropped = 0
        while dropped < 3, String(data: text, encoding: .utf8) == nil, !text.isEmpty {
            text = text.dropLast()
            dropped += 1
        }
        guard String(data: text, encoding: .utf8) != nil else {
            return .failure("That file is not text or a picture, so there is nothing to show here.")
        }
        return .contents(text, kind: kind, totalBytes: totalBytes)
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

    /// What to tell the phone when a change to the tree says no.
    ///
    /// A third vocabulary beside ``browseMessage(for:)`` and ``FileReplacement.message(for:)``, and the split
    /// is the same one those two already make: each names the failures its own kind of operation
    /// actually produces. What is new here is the name. Reading a file cannot fail because
    /// something is already called that, and writing one replaces rather than creates — so
    /// "already there" is a sentence only this path needs, and it is the sentence a user meets
    /// most often, because it is what happens when they rename something to a name already in
    /// the folder.
    private static func changeMessage(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteFileExistsError:
                return "Something with that name is already there."
            // A file or folder that was removed, or that somebody renamed, between the listing
            // going out and this arriving. The row the user tapped was real when they tapped it.
            case NSFileNoSuchFileError:
                return "That is no longer there."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return message(forErrno: EPERM)
            case NSFileWriteVolumeReadOnlyError:
                return "That disk can only be read from, so nothing can be changed on it."
            case NSFileWriteOutOfSpaceError:
                return FileReplacement.message(for: error)
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            // Raised by `mkdir` and by `rename` when the last component of the path is too long.
            case ENAMETOOLONG:
                return "That name is too long for this Mac."
            default:
                return message(forErrno: Int32(error.code))
            }
        }
        return error.localizedDescription
    }

    // MARK: - Changing the tree

    /// One change to a folder, on a queue that is not the one carrying keystrokes.
    ///
    /// Dispatched for the reason ``list(id:requested:sink:)`` is: this is disk work on a path that
    /// may be a network volume — and a recursive delete on one takes as long as it takes — so it
    /// happens off the connection's own queue, and the answer comes back through the sink the
    /// shell's output already arrives on.
    ///
    /// The path is standardised for the work and echoed back as it arrived, which is the split
    /// ``write(id:path:data:isLast:ownerClientID:sink:)`` already makes. The two are the same
    /// file; they are not always the same string, and the client is holding the string it sent.
    private func change(id: UUID, operation: RemoteFileOperation, sink: @escaping Sink) {
        // Named by what it is about, because everything below is either one of these or a
        // sentence: the work is a function of a path and the answer is a path.
        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        // Tested on the string that arrived, like every other browse request — see
        // ``list(id:requested:sink:)``. A relative path would resolve against this process's
        // working directory rather than the shell's, which is the directory the user believes
        // they are looking at.
        guard path.hasPrefix("/") else {
            sink(.fileOperationFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can change."
            ))
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.perform(operation, at: url) {
            case .done(let note):
                sink(.fileOperationDone(sessionID: id, path: path, note: note))
            case .failure(let message):
                sink(.fileOperationFailure(sessionID: id, path: path, message: message))
            }
        }
    }

    private enum ChangeOutcome {
        case done(String)
        case failure(String)
    }

    /// Does the work, and says what to put in the log.
    ///
    /// The note is written here rather than on the phone because this is the side that watched it
    /// happen: it is the side that counted what a folder held before it went, and the side that
    /// knows whether "delete" meant the Trash or was refused.
    private static func perform(_ operation: RemoteFileOperation, at url: URL) -> ChangeOutcome {
        // Qualified, because `create` and `rename` are also the names of two instance methods
        // that act on a terminal rather than on a file. The two are different things that happen
        // to share a word, and the compiler can tell them apart — this is for the reader.
        switch operation {
        case .create(_, let kind):
            return Self.create(at: url, kind: kind)
        case .rename(_, let name):
            return Self.rename(at: url, to: name)
        case .delete:
            return Self.delete(at: url)
        }
    }

    /// An empty file, or a folder.
    ///
    /// **One new name and nothing above it, for both kinds.** The browser only ever asks for a
    /// single thing in the folder it is showing — the phone's rule refuses a slash before it is
    /// sent — so a path with two new components in it is either a bug or a client that has been
    /// got at, and the answer to both is to refuse rather than to build a tree somebody did not
    /// ask for. `withIntermediateDirectories: false` is the same decision made again by the
    /// filesystem, so a race cannot slip past the check above it.
    private static func create(at url: URL, kind: RemoteEntryKind) -> ChangeOutcome {
        let name = url.lastPathComponent
        guard RemoteFileName.isValid(name) else {
            return .failure("That is not a name a file can have.")
        }
        // Tested before either creation path, so "there is nowhere to put it" is one sentence
        // instead of a `createDirectory` failure the account may not be at fault for.
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return .failure("That folder is no longer there.")
        }

        switch kind {
        case .folder:
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false
                )
            } catch {
                return .failure(changeMessage(for: error))
            }
            return .done("created folder \(name)")

        case .file:
            // `open` with `O_EXCL` rather than `createFile`, and the reason is the message rather
            // than the mechanism. `createFile` answers a Bool that is "no" for a file that is
            // already there, a folder that is not, and one this account may not write into — so
            // the code would have to guess which sentence to show, and the obvious guess is the
            // one that tells the user about permissions when the real answer is that the name is
            // taken. `EEXIST` is that answer, stated outright.
            //
            // Exclusive also closes the race: two clients creating the same name at the same
            // moment have one winner and one honest refusal, rather than one silently replacing
            // the other's empty file.
            let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                return .failure(changeMessage(for: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )))
            }
            // Qualified for the same reason as the two above: this type has a `close` of its own
            // that ends a terminal.
            Darwin.close(descriptor)
            return .done("created file \(name)")
        }
    }

    /// A new name for something already in a folder.
    ///
    /// The name arrives rather than the path it becomes, so this is not a move: the new path is
    /// built by replacing the last component of the old one, and there is no way to express
    /// "somewhere else entirely". `moveItem` refuses a destination that already exists, so nothing
    /// is ever clobbered by a rename — the user is told the name is taken and keeps both files.
    private static func rename(at url: URL, to name: String) -> ChangeOutcome {
        // The second of the two checks on a name — the phone makes the first — and the one that
        // matters, since this end cannot see the keyboard the name was typed on.
        guard RemoteFileName.isValid(name) else {
            return .failure("That is not a name a file can have.")
        }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
        guard renamed.path != url.path else {
            return .done("renamed \(url.lastPathComponent) to \(name)")
        }

        do {
            try FileManager.default.moveItem(at: url, to: renamed)
        } catch {
            return .failure(changeMessage(for: error))
        }
        return .done("renamed \(url.lastPathComponent) to \(name)")
    }

    /// A file, or a folder and everything in it.
    ///
    /// **To the Trash rather than to nothing.** This app runs on somebody's own Mac, where the
    /// difference between a mistaken delete and a lost one is the whole of whether they trust the
    /// button. `trashItem` moves a tree of any size in one move and hands back where it went, so
    /// the file is in the Finder afterwards and can be put back — which is what makes a recursive
    /// delete safe enough to offer from a phone at all. It is also why nothing here asks a second
    /// time: the phone's confirmation already said what would happen, and a Mac that asked again
    /// would be asking a question nobody is sitting in front of.
    ///
    /// **Nothing is ever followed.** A symbolic link is a file that points somewhere, and the two
    /// ends of it are different things to delete: removing the link is what a row showing a link
    /// means, and removing its target is somebody's folder going because they deleted a shortcut.
    /// **That `trashItem` unlinks a link rather than descending through it was verified rather
    /// than assumed**, because it is the one assumption here that could lose data quietly: a
    /// shortcut to a folder was trashed and the folder, its subfolder and the file inside it were
    /// all still in place afterwards, with the link itself the only thing that went.
    private static func delete(at url: URL) -> ChangeOutcome {
        let name = url.lastPathComponent
        // Guard rails against a bug rather than against a user: the browser draws a row per entry
        // and the row that would name the folder you are standing in does not exist, so nothing in
        // the app can ask for these. A client that has been got at can.
        //
        // Tested against the home folder by **containment and not equality**, which is the whole
        // of why this is a function in `RemoteCore` rather than a comparison here: equality
        // against `/` and the home folder alone leaves `/Users` — every account on the machine —
        // as a legal thing to delete. `pathContains` also covers `/` for free, since the root
        // contains everything.
        guard !pathContains(url.path, FileManager.default.homeDirectoryForCurrentUser.path) else {
            return .failure("That is too much of this Mac to delete.")
        }

        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let isFolder = values?.isDirectory == true
        // Counted before the move, because afterwards there is nothing left to walk. One pass over
        // the tree, which for a folder of a few files is free and for a folder of a hundred
        // thousand is the price of saying an honest number — and the answer is only ever used for
        // that sentence.
        let contents = isFolder && values?.isSymbolicLink != true
            ? (Self.countInside(url) ?? 1)
            : 1

        do {
            var moved: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
            return .done(contents == 1
                ? "moved \(name) to the Trash"
                : "moved \(name) and \(contents - 1) more to the Trash")
        } catch {
            return .failure(changeMessage(for: error))
        }
    }

    /// How many entries are inside a folder, itself included — or nothing if it cannot be walked.
    ///
    /// A count rather than a list: nothing wants the names, and holding a hundred thousand of them
    /// to produce one number would be the memory this app spends on somebody's terminal instead.
    /// `nil` means the tree could not be read, and is answered as a folder holding one thing,
    /// which makes the sentence say what it always says rather than inventing a figure.
    private static func countInside(_ url: URL) -> Int? {
        guard let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            // The default, spelled out: a link is listed rather than entered, which is the same
            // rule the delete itself follows and the reason the two agree on the count.
            options: [],
            // A folder inside that cannot be read stops that branch and leaves the walk going,
            // rather than failing the whole count and taking the honest number down with it.
            errorHandler: { _, _ in true }
        ) else { return nil }

        // From one, because the folder itself is going too. Every step of the walk is one more
        // thing: a subfolder is counted here and so are its contents, and a link is one thing
        // whatever it points at.
        var count = 1
        while walk.nextObject() != nil { count += 1 }
        return count
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
