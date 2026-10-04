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
        /// The name the tab shows. Resolved from the two below rather than set directly, so one
        /// place decides which of them wins.
        var name: String
        let process: Process
        let master: FileHandle
        var isRunning = true
        var history = Data()
        var attentionDetector = TerminalAttentionDetector()
        var finishDetector = TerminalCommandFinishDetector()
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
    /// The write lands in one move or it does not land at all: a file written piece by piece into
    /// place is half the old contents and half the new for as long as the transfer takes, and the
    /// thing being replaced is somebody's script. The pieces wait in a scratch file beside the
    /// destination, under a name nothing will look for, and the destination is untouched until the
    /// last piece arrives and the scratch file is moved over it.
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
        /// Opened on the first piece rather than here, so the request that opens a transfer does no
        /// disk work on the queue that carries every keystroke the phone sends.
        var handle: FileHandle?
        /// How many bytes have been appended. Touched only under the manager's lock.
        var received = 0
        /// The first thing that went wrong writing to disk, if anything did.
        ///
        /// Recorded rather than reported, because thousands of pieces may still be coming and the
        /// user is owed one answer at the end. Once set, the pieces after it are dropped: a
        /// transfer with a hole in it is not a file.
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
        /// Called on the write queue rather than under the lock, since closing a handle is a disk
        /// operation and one caller is the teardown path that runs holding the lock.
        func discard() {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// The one queue every write's disk work happens on.
    ///
    /// Not the connection's queue, which carries every keystroke the phone sends: a piece appended
    /// there is a keystroke delayed by however long a path on a network volume takes to answer.
    ///
    /// One queue rather than one per transfer: what matters is that one transfer's pieces are
    /// appended in the order they arrived, which a single serial queue gives for free.
    private static let writeIO = DispatchQueue(
        label: "pl.dmq.peering.host.write",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var sinks: [String: Sink] = [:]
    private var writes: [WriteKey: PendingWrite] = [:]

    /// Called when a terminal needs the user's attention, or has finished a command worth
    /// mentioning, and the client's sink is gone, meaning the phone is no longer connected over the
    /// control channel. Token is the APNs hex token; title and message are the notification's own
    /// title and body — carried through rather than a ``TerminalAttentionKind``, since "finished"
    /// is not a kind of attention and the two need different titles.
    var onPushNeeded: (@Sendable (String, String, String) -> Void)?

    /// The APNs tokens of clients that have registered for push but are not connected over the
    /// control channel. Used by native-terminal watching to push outside of Peering sessions.
    func allPushTokens() -> [String] {
        // Read before the lock below rather than inside it: the store has a lock of its own, and one
        // lock order held everywhere is one fewer way for the two to deadlock.
        let tokens = PushTokenStore.shared.tokensByClient()
        return lock.withLock {
            tokens.compactMap { clientID, token in
                sinks[clientID] == nil ? token : nil
            }
        }
    }

    /// Every token this Mac holds, whether or not the phone that gave it is connected.
    ///
    /// The question ``allPushTokens()`` deliberately does not answer: a connected client is left
    /// out of that list because a terminal needing attention is told to it over the session rather
    /// than pushed, so "does this Mac hold a token at all" answered no whenever a phone was
    /// connected.
    func registeredPushTokens() -> [String] {
        Array(PushTokenStore.shared.tokensByClient().values)
    }

    /// How many of the registered phones are connected right now.
    func connectedPushClientCount() -> Int {
        let clients = PushTokenStore.shared.tokensByClient().keys
        return lock.withLock { clients.filter { sinks[$0] != nil }.count }
    }
    private static let maximumHistoryBytes = 512 * 1024
    /// How far past it a shell's history may run before the tail is rebuilt, so trims are batched rather
    /// than paid on every chunk.
    private static let historySlackBytes = 64 * 1024
    private static let maximumSessionsPerClient = 10

    /// One terminal's write to one path.
    ///
    /// Keyed by both: two phones watching the same Mac are two people, and one uploading into a
    /// folder must not disturb the other's transfer. Keyed by the terminal so closing a shell
    /// abandons exactly the transfers made through it.
    ///
    /// The path is the key rather than an identifier carried on the wire, because the interesting
    /// collision is one terminal beginning the same file twice, and the only sensible answer is
    /// that the newer attempt wins.
    private struct WriteKey: Hashable {
        let sessionID: UUID
        let path: String
    }

    /// How large a file this Mac will take from a phone.
    ///
    /// Two gigabytes, which covers what this limit is actually met by: a video clip. A ceiling
    /// rather than no ceiling, because a transfer cannot be stopped once started and a mis-tap on a
    /// folder of raw footage should not commit somebody to an hour of it. Declared on both ends,
    /// since a limit only one end enforces holds until the other end is older.
    private static let maximumWriteBytes = 2 * 1_073_741_824
    /// How much of a file may travel in one message.
    ///
    /// The mirror of ``previewChunkBytes``, and the same number because the constraint is the same:
    /// a `Data` on this channel is base64 in JSON, so thirty-two kilobytes of file is some
    /// forty-three of payload against a ``ProtocolInfo/maxControlPayload`` of sixty-four. Refused
    /// rather than trimmed.
    private static let writeChunkBytes = 32 * 1024

    /// How many entries one listing carries. The listing crosses the same connection as the shell's
    /// output, and a directory like `/usr/bin` is several thousand rows the user will scroll past.
    /// The answer says it was cut, so the client can say so too.
    private static let maximumDirectoryEntries = 2_000
    /// How much of a file a preview shows.
    ///
    /// Picked against the screen rather than the file: the phone draws what it is sent as one piece
    /// of text, so this is also the most text it has to lay out, and a hundred kilobytes is some
    /// two thousand lines. A longer file is shown from the beginning and said to be, not refused.
    private static let maximumPreviewBytes = 128 * 1024
    /// How much of a *picture* a preview shows.
    ///
    /// Sixty-four times the text cap, because the two answer different questions: a preview that
    /// stops a third of the way into a JPEG is not a smaller picture, it is no picture at all,
    /// since there is nothing useful to draw from the first bytes of one. Eight megabytes covers a
    /// phone photo and a screenshot with room to spare.
    private static let maximumImagePreviewBytes = 8 * 1024 * 1024
    /// How much of a file travels per event. Comfortably inside the 64 KB the control channel
    /// accepts for a request, and small enough that a preview never sits in front of a keystroke
    /// for long.
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
            lock.withLock { session.attentionDetector.userDidRespond() }
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

        case .registerPushToken(let tokenData):
            // Empty means forget me: the phone sends no bytes when its plan stops including being
            // told about a terminal, and the token it gave earlier is dropped. Stored nil rather
            // than "", because the push path tests the token for existence and a registered ""
            // would be sent to APNs as a device nobody can reach.
            let hex = tokenData.isEmpty
                ? nil
                : tokenData.map { String(format: "%02x", $0) }.joined()
            PushTokenStore.shared.set(hex, for: clientID)
        }
    }

    /// A terminal this client owns and can still type into.
    ///
    /// The identifier arrives from the network, so every request touching a shell asks this first:
    /// without it an authenticated client could name a terminal belonging to another device.
    private func liveSession(_ id: UUID, ownerClientID: String) -> Session? {
        lock.withLock {
            guard let session = sessions[id],
                  session.ownerClientID == ownerClientID,
                  session.isRunning else { return nil }
            return session
        }
    }

    func disconnect(clientID: String) {
        // Whatever it was in the middle of writing goes with it: an unfinished transfer is not a
        // file waiting to be resumed, because the client that would claim it is the one that has
        // just gone.
        let abandoned = lock.withLock { () -> [PendingWrite] in
            let mine = writes.values.filter { $0.ownerClientID == clientID }
            writes = writes.filter { $0.value.ownerClientID != clientID }
            _ = sinks.removeValue(forKey: clientID)
            return mine
        }
        // The pieces have to be deleted, not merely dropped: they are on somebody's disk as a
        // scratch file beside the destination, and leaving those behind fills a folder with the
        // ghosts of every failed upload. On the write queue, so the removal lands after any append
        // still in flight for the same transfer.
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
        // Foundation's Process can attach the slave descriptors but does not make them the child's
        // controlling terminal. `script` does the forkpty/setsid/TIOCSCTTY setup, so job control
        // and password prompts behave like a real Terminal window.
        let shell = loginShell()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shell, "-l"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // These shells are drawn on a phone by replaying their bytes onto a grid, so a program that
        // repaints cell by cell is every weakness at once, and that is what a full-screen program
        // on the alternate screen does. This is Claude Code's documented way of being told not to:
        // classic draws on the main screen and flows into the scrollback. Set for the shells this
        // app opens only, so a Terminal window on the same Mac keeps what its owner chose.
        environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] = "1"
        if shell.hasSuffix("zsh") { Self.installZshFinishHook(into: &environment) }
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
            // The spawned process owns duplicated slave descriptors: keeping the parent's copy
            // open would prevent EOF on the master after the shell exits.
            try? slave.close()
            if shell.hasSuffix("bash") { Self.installFinishHook(shell: shell, into: master) }
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

    /// The precmd/preexec-equivalent hook for each shell this app knows how to talk to, one
    /// compact statement so it survives being typed onto a single input line. Both write the same
    /// OSC marker ``TerminalCommandFinishDetector`` looks for, and both check the five-second
    /// threshold themselves, so a trivial command never even produces a marker to detect.
    ///
    /// **zsh**: a real `preexec`/`precmd` pair, appended to zsh's own cooperative hook arrays —
    /// safe regardless of what the user's own `.zshrc` also appends there.
    ///
    /// **bash**: not a `DEBUG` trap. An early version used one, guarded by an "am I inside precmd"
    /// flag the way the well-known `bash-preexec` project does, and a real interactive bash (not a
    /// `-c` script) still fires that trap for the trap's own invocation before the guard can be
    /// set, corrupting the very timer it exists to protect — verified by driving a real PTY-backed
    /// interactive bash rather than assumed. Reading the start time back out of `history 1`
    /// (`HISTTIMEFORMAT` set to a raw epoch) sidesteps the whole recursion question: nothing hooks
    /// command execution at all, precmd alone computes elapsed time from what the shell already
    /// recorded.
    private static let zshFinishHookLine =
        #"zmodload zsh/datetime 2>/dev/null; __mc_preexec(){ __mc_t0=$EPOCHREALTIME; __mc_cmd=$1; }; __mc_precmd(){ local __mc_s=$?; if [[ -n $__mc_t0 ]]; then local __mc_d=$(( (EPOCHREALTIME - __mc_t0) * 1000 )); __mc_d=${__mc_d%.*}; if (( __mc_d >= 5000 )); then printf '\033]9999;%s;%s;%s\007' "$__mc_d" "$__mc_s" "$(printf %s "$__mc_cmd" | base64 | tr -d '\n')"; fi; unset __mc_t0; fi }; precmd_functions+=(__mc_precmd); preexec_functions+=(__mc_preexec)"#

    private static let bashFinishHookLine =
        #"export HISTTIMEFORMAT="%s "; set -o history; __mc_last=""; __mc_precmd(){ local __mc_s=$?; local __mc_line; __mc_line=$(history 1); local __mc_ts=$(printf '%s\n' "$__mc_line" | awk '{print $2}'); local __mc_cmd=$(printf '%s\n' "$__mc_line" | awk '{$1="";$2="";print}' | sed 's/^  *//'); local __mc_now=$(date +%s); local __mc_d=$(( (__mc_now - __mc_ts) * 1000 )); if [ "$__mc_line" != "$__mc_last" ] && [ "$__mc_d" -ge 5000 ]; then printf '\033]9999;%s;%s;%s\007' "$__mc_d" "$__mc_s" "$(printf %s "$__mc_cmd" | base64 | tr -d '\n')"; fi; __mc_last="$__mc_line"; }; PROMPT_COMMAND="__mc_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#

    /// Points zsh at a directory of wrapper dotfiles that source the real ones and then add the
    /// finish hook, so the hook arrives as configuration and not as typed input.
    ///
    /// Trap: macOS's `/etc/zshrc` runs before the user's `.zshrc` and sets `HISTFILE` from
    /// `$ZDOTDIR`, so the wrapper has to put it back or history is written into the temp directory.
    private static func installZshFinishHook(into environment: inout [String: String]) {
        let wrapper = FileManager.default.temporaryDirectory.appendingPathComponent("peering-zdotdir", isDirectory: true)
        let home = environment["ZDOTDIR"] ?? NSHomeDirectory()
        func forward(_ name: String, extra: String = "") -> String {
            """
            ZDOTDIR=$PEERING_USER_ZDOTDIR
            [[ -f $ZDOTDIR/\(name) ]] && source $ZDOTDIR/\(name)
            \(extra)ZDOTDIR=$PEERING_WRAPPER_ZDOTDIR

            """
        }
        let zshrc = forward(".zshrc", extra: zshFinishHookLine + "\n")
        let zlogin = forward(".zlogin", extra: "")
            + "if [[ -n $PEERING_HAD_ZDOTDIR ]]; then ZDOTDIR=$PEERING_USER_ZDOTDIR; else unset ZDOTDIR; fi\n"
        let files = [
            ".zshenv": forward(".zshenv"),
            ".zprofile": forward(".zprofile"),
            ".zshrc": "[[ $HISTFILE == $PEERING_WRAPPER_ZDOTDIR/* ]] && HISTFILE=$PEERING_USER_ZDOTDIR/${HISTFILE:t}\n" + zshrc,
            ".zlogin": zlogin,
        ]
        do {
            try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
            for (name, text) in files {
                try text.write(to: wrapper.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            terminalLog.error("could not write the zsh wrapper: \(error.localizedDescription, privacy: .public)")
            return
        }
        environment["PEERING_USER_ZDOTDIR"] = home
        environment["PEERING_WRAPPER_ZDOTDIR"] = wrapper.path
        if environment["ZDOTDIR"] != nil { environment["PEERING_HAD_ZDOTDIR"] = "1" }
        environment["ZDOTDIR"] = wrapper.path
    }

    /// Typed into the master like keystrokes, which echoes it once at the top of a new tab. Only bash
    /// still comes this way: it has no equivalent of the `ZDOTDIR` wrapper below for a login shell.
    ///
    /// Skipped for anything that is not recognisably bash: no hook, no feature, no risk to a shell
    /// this does not know how to talk to.
    private static func installFinishHook(shell: String, into master: FileHandle) {
        let line = bashFinishHookLine
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? master.write(contentsOf: data)
    }

    private func received(_ data: Data, from session: Session) {
        let (attention, finish, question): (
            TerminalAttentionKind?, TerminalCommandFinishDetector.Finish?, String?
        ) = lock.withLock {
            guard sessions[session.id] === session else { return (nil, nil, nil) }
            session.history.append(data)
            // Rebound rather than cut with `removeFirst`, which moves `Data`'s start index instead of
            // compacting and so keeps the whole stream alive behind a buffer that looks its limit.
            if session.history.count > Self.maximumHistoryBytes + Self.historySlackBytes {
                let dropped = session.history.count - Self.maximumHistoryBytes
                session.history = Data(session.history.dropFirst(dropped))
            }
            let kind = session.attentionDetector.receive(data)
            // Read inside the lock and in the same breath as the detection: the question is the
            // tail the detection just recognised, and the tail moves on with the next output.
            return (kind, session.finishDetector.receive(data), session.attentionDetector.question)
        }

        send(.output(sessionID: session.id, data: data), to: session.ownerClientID)

        if let attention {
            let noun = attention == .password ? "a password" : "confirmation"
            let name = "Terminal \u{201C}\(session.name)\u{201D}"
            // The prompt alone when there is one: "[sudo] password for damian:" says which password
            // and whose. The sentence stays as the fallback for a prompt that cannot be read.
            let message = question ?? "\(name) is waiting for \(noun)."
            send(.attention(sessionID: session.id, kind: attention, message: message), to: session.ownerClientID)
            push(session: session, title: "Terminal needs you", message: message)
        }

        if let finish {
            send(
                .commandFinished(
                    sessionID: session.id,
                    command: finish.command,
                    duration: finish.duration,
                    exitStatus: finish.exitStatus
                ),
                to: session.ownerClientID
            )
            let named = finish.command.map { "\u{201C}\($0)\u{201D}" } ?? "Terminal \u{201C}\(session.name)\u{201D}"
            let message = "\(named) finished\(TerminalCommandFinishDetector.durationSuffix(finish.duration))."
            push(session: session, title: "Terminal finished", message: message)
        }
    }

    /// Sends terminal alerts through APNs whenever this device has registered a token.
    ///
    /// A connected control channel is not proof that the phone can raise a local notification:
    /// Picture in Picture deliberately keeps that channel alive while the app is backgrounded, and
    /// iOS may suspend the app before it handles the terminal event. APNs is system-owned and keeps
    /// working in exactly that state. The control event is still sent above so the terminal UI stays
    /// current; the phone suppresses its local banner when it has an APNs token, avoiding duplicates.
    private func push(session: Session, title: String, message: String) {
        guard let token = PushTokenStore.shared.token(for: session.ownerClientID) else { return }
        onPushNeeded?(token, title, message)
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
        // A write made through this shell cannot be finished, since every piece after this one is
        // refused for naming a terminal that is gone. Dropped here rather than refused chunk by
        // chunk.
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
    /// Answered off the connection's own queue, which carries every keystroke the phone sends:
    /// `contentsOfDirectory` blocks, and on a network volume or behind a consent prompt it takes as
    /// long as it takes. The answer comes back through the sink the shell's output already arrives
    /// on.
    private func list(id: UUID, requested: String?, sink: @escaping Sink) {
        // Absolute paths only: a relative one resolves against this process's working directory
        // rather than the shell's, which is the directory the user believes they are looking at.
        // Not an authorization boundary either way, since whoever owns this terminal already has a
        // login shell as this user.
        //
        // Tested on the string that arrived, not on the `URL`: `URL(fileURLWithPath:)` quietly makes
        // a relative path absolute against the process's working directory, so a check after it
        // would pass every time and mean nothing.
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.browseFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can open."
            ))
            return
        }
        // Standardised for the answer rather than the lookup, so the path the phone puts in its
        // breadcrumbs is one it can send back. Symbolic links are left alone: a folder reached
        // through one is the folder the user asked for.
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
    /// never finishes leaves what was there exactly as it was, which is why this is two requests
    /// rather than the client naming a path and starting to send.
    ///
    /// The path is tested on the string that arrived, like the two above it, and for the reason
    /// given there.
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
        // Standardised but not resolved: the answer names the path the client sent, and following
        // the link is ``commit(_:to:)``'s job.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let key = WriteKey(sessionID: id, path: url.path)
        // Resolved here, once, rather than at the move: `resolvingSymlinksInPath` is a stat call per
        // component, and this is the one moment it is affordable on a queue that carries keystrokes.
        let target = url.resolvingSymlinksInPath()
        // Derived from the destination behind a leading dot, so it is hidden and sorts beside the
        // file it becomes, and carries a UUID so a second transfer of the same path (which replaces
        // this record) appends to a different file rather than into this one.
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
    /// Answered off the connection's own queue for the reason the listing is: disk work on a path
    /// that may be a network volume, on a queue that carries every keystroke the phone sends.
    private func write(
        id: UUID,
        path: String,
        data: Data,
        isLast: Bool,
        ownerClientID: String,
        sink: @escaping Sink
    ) {
        // Standardised the same way ``beginWrite(id:path:totalBytes:ownerClientID:sink:)`` did, or a
        // path written two ways is two different keys and every piece arrives for a transfer nobody
        // opened.
        let key = WriteKey(sessionID: id, path: URL(fileURLWithPath: path).standardizedFileURL.path)
        // The check is against the request as it will be encoded, not the file: base64 in JSON makes
        // a small-looking chunk three-quarters again as large as a payload, and a message over the
        // cap takes the session down rather than being refusable. Refused here, where there is still
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
        /// anything: a chunk that is not the last is accepted with silence, which a two-case result
        /// would have to spell as a refusal with nothing in it.
        enum State {
            case more(PendingWrite, Data)
            case ready(PendingWrite, Data)
            case refused(String)
        }
        let state: State = lock.withLock {
            guard let pending = writes[key] else {
                return .refused("That file is no longer being written. Choose it again.")
            }
            // The declared size is the only thing that says when a file is whole, so a transfer
            // that has stopped agreeing with it has no correct end.
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
            // The accounting happens here; the bytes go to disk on their own queue. The pieces are
            // enqueued in the order they arrived on one serial queue, so the file they build is the
            // same whether the handle is opened by the first piece or the twentieth.
            //
            // Nothing is said back: this is one of a few thousand messages, and an acknowledgement
            // each would double the traffic to report progress nothing on screen is showing.
            Self.writeIO.async { Self.append(piece, to: pending) }

        case .refused(let message):
            // Whatever was already appended is thrown away and the destination was never touched. A
            // refusal can arrive after several thousand pieces have gone to disk, which is why the
            // scratch file exists rather than the destination being written.
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
                    // Answered with the path as it arrived, not the standardised one written to:
                    // same file, not always the same string, and the client is holding the one it
                    // sent. An answer it cannot match leaves an editor spinning.
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
    /// Runs on ``writeIO`` and nowhere else, so the lazy open needs no lock and no ordering care:
    /// the pieces are enqueued in the order they arrived, so the first call is the first piece.
    ///
    /// A failure is recorded rather than reported. See ``PendingWrite/failure``.
    private static func append(_ piece: Data, to pending: PendingWrite) {
        guard pending.failure == nil else { return }

        if pending.handle == nil {
            do {
                // An empty write rather than `createFile`, because this form answers with why it
                // could not: somebody else's folder, a full volume and a deleted directory all look
                // the same from a `Bool`.
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
        // wrong silently: a replacement that has quietly become a copy across volumes works until
        // the moment it does not.
        report(FileReplacement.commit(staging: pending.staging, to: pending.target))
    }

    /// A preview, in pieces.
    ///
    /// The cut is by bytes and the text is not, so a boundary can fall inside a UTF-8 character and
    /// the client joins the pieces before decoding them. The last piece says it is the last, and
    /// `totalBytes` tells a whole file from the beginning of one.
    ///
    /// Every piece carries the kind, the same value each time, because the client has to know what
    /// it is holding before the first piece is drawn and no piece is marked as the one to read it
    /// from.
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

    /// No size among them: `URLResourceValues` has no key for the mode bits, so both come from one
    /// `attributesOfItem` instead, which is the call that has to be used anyway because `fileSize`
    /// answers nothing for a folder.
    private static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]

    private static func entries(in directory: URL) -> ListingOutcome {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(entryKeys),
                // Hidden entries are listed rather than skipped: which to show is the phone's
                // decision, and a filter here would be a second answer to a question the client
                // already answers. The SSH browser this will serve next has its own idea of
                // "hidden".
                options: []
            )
        } catch {
            return .failure(browseMessage(for: error))
        }

        // Folders first, then by name, and sorted here rather than on the phone so every client
        // shows the same order. `localizedStandardCompare` is how the Finder compares, so `file 10`
        // follows `file 9` rather than `file 1`.
        let entries = urls.compactMap(entry(for:)).sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
        // Cut after the sort, so what arrives is the beginning of a real order rather than whatever
        // order the filesystem handed over.
        return .entries(
            Array(entries.prefix(Self.maximumDirectoryEntries)),
            truncated: entries.count > Self.maximumDirectoryEntries
        )
    }

    /// One row, or nothing for an entry that could not be described.
    ///
    /// Dropped rather than fatal: a file deleted between the listing and the look is a missing row,
    /// not a folder that failed to open.
    private static func entry(for url: URL) -> RemoteDirectoryEntry? {
        guard let values = try? url.resourceValues(forKeys: entryKeys) else { return nil }

        let isSymlink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false
        if isSymlink {
            // A link reports its own type rather than its target's, and a link to a folder is a
            // folder as far as a tap on the row goes. `fileExists` follows the link, which is the
            // question here, and only links pay for the second look.
            var pointsAtDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &pointsAtDirectory) {
                isDirectory = pointsAtDirectory.boolValue
            }
        }

        // One look for the mode bits and the size, the pair `ls -l` prints a row of. A folder
        // included: the number beside one is the bytes its own entry takes.
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
    /// The one field here with no resource-value key of its own, so it comes from the same call
    /// ``entry(for:)`` takes the size from, which is why the attributes arrive rather than a path.
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
        // The three that sit on top of an execute bit and print in its place: `s` where it is set
        // too and `S` where it is not, likewise `t` and `T` for the sticky bit.
        var characters = Array(bits)
        if mode & 0o4000 != 0 { characters[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { characters[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { characters[8] = mode & 0o001 != 0 ? "t" : "T" }
        return type + String(characters)
    }

    /// A file's contents, bounded: its text if it is text, and its bytes if it is a picture.
    ///
    /// Each refusal is a thing the user would otherwise meet as a broken screen: not a file, not
    /// readable, neither text nor a picture this can show, and too long to show whole (which is a
    /// beginning rather than a refusal).
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
            // A read may return less than it was asked for, so it is asked again until the cap or
            // the end of the file.
            //
            // Two passes, because the first decides the size of the second: what the head of the
            // file turns out to be is what says how much of the rest is worth carrying.
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

        // `isDrawn` set the cap above; this is a different question. A raster image is bytes and
        // goes exactly as it was read; text and SVG are text on the wire, which has one more thing
        // to answer before it can be sent.
        if kind == .image { return .contents(data, kind: kind, totalBytes: totalBytes) }

        // It has to decode. Up to three bytes come off the end first, for the case where the read
        // stopped at the cap rather than the end of the file and the cut landed inside a character:
        // calling a text file binary because it was long is the wrong answer.
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
    /// macOS answers EPERM both when the consent prompt was declined and when it has not been shown
    /// yet, so the permission sentence names the setting rather than guessing which of the two it
    /// was. It is the only failure here the user can do anything about.
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
    /// A third vocabulary beside ``browseMessage(for:)`` and ``FileReplacement.message(for:)``, each
    /// naming the failures its own kind of operation produces. "Already there" is a sentence only
    /// this path needs, since reading cannot fail that way and writing replaces rather than creates,
    /// and it is the one a user meets most often: renaming to a name already in the folder.
    private static func changeMessage(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteFileExistsError:
                return "Something with that name is already there."
            // Removed or renamed between the listing going out and this arriving: the row the user
            // tapped was real when they tapped it.
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
    /// Dispatched for the reason ``list(id:requested:sink:)`` is: disk work on a path that may be a
    /// network volume, where a recursive delete takes as long as it takes. The answer comes back
    /// through the sink the shell's output already arrives on.
    ///
    /// The path is standardised for the work and echoed back as it arrived, the split
    /// ``write(id:path:data:isLast:ownerClientID:sink:)`` already makes: same file, not always the
    /// same string, and the client is holding the string it sent.
    private func change(id: UUID, operation: RemoteFileOperation, sink: @escaping Sink) {
        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        // Tested on the string that arrived, for the reason given in ``list(id:requested:sink:)``.
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
    /// happen: it counted what a folder held before it went, and knows whether "delete" meant the
    /// Trash or was refused.
    private static func perform(_ operation: RemoteFileOperation, at url: URL) -> ChangeOutcome {
        // Qualified, because `create` and `rename` are also the names of two instance methods that
        // act on a terminal rather than on a file.
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
    /// One new name and nothing above it, for both kinds: the browser only ever asks for a single
    /// thing in the folder it is showing, so a path with two new components is either a bug or a
    /// client that has been got at, and the answer to both is to refuse rather than build a tree
    /// nobody asked for. `withIntermediateDirectories: false` is the filesystem making the same
    /// decision again, so a race cannot slip past the check.
    private static func create(at url: URL, kind: RemoteEntryKind) -> ChangeOutcome {
        let name = url.lastPathComponent
        guard RemoteFileName.isValid(name) else {
            return .failure("That is not a name a file can have.")
        }
        // Tested before either creation path, so "there is nowhere to put it" is one sentence
        // rather than a `createDirectory` failure this account may not be at fault for.
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
            // `open` with `O_EXCL` rather than `createFile`, for the message rather than the
            // mechanism: `createFile` answers a Bool that is "no" for a name already taken, a
            // folder that is not there, and one this account may not write into, so the code would
            // have to guess which sentence to show, and the obvious guess blames permissions when
            // the name is taken. Exclusive also closes the race: two clients creating the same name
            // have one winner and one honest refusal.
            let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                return .failure(changeMessage(for: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )))
            }
            // Qualified like the two above: this type has a `close` of its own that ends a terminal.
            Darwin.close(descriptor)
            return .done("created file \(name)")
        }
    }

    /// A new name for something already in a folder.
    ///
    /// The name arrives rather than the path it becomes, so this is not a move: the new path is
    /// built from the old one's last component and there is no way to express "somewhere else
    /// entirely". `moveItem` refuses an existing destination, so nothing is ever clobbered: the
    /// user is told the name is taken and keeps both files.
    private static func rename(at url: URL, to name: String) -> ChangeOutcome {
        // The second of the two checks on a name, and the one that matters, since this end cannot
        // see the keyboard the name was typed on.
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
    /// To the Trash rather than to nothing: `trashItem` moves a tree of any size in one move, so
    /// the file is in the Finder afterwards and can be put back, which is what makes a recursive
    /// delete safe enough to offer from a phone. Nothing asks a second time, because the phone's
    /// confirmation already said what would happen and nobody is sitting in front of the Mac.
    ///
    /// Nothing is ever followed. Removing the link is what a row showing a link means; removing its
    /// target is somebody's folder going because they deleted a shortcut. That `trashItem` unlinks
    /// a link rather than descending through it was verified, not assumed, since it is the one
    /// assumption here that could lose data quietly.
    private static func delete(at url: URL) -> ChangeOutcome {
        let name = url.lastPathComponent
        // Guard rails against a bug rather than a user: no row in the browser can name the folder
        // you are standing in. A client that has been got at can.
        //
        // Tested by containment and not equality, which is why this is a function in `RemoteCore`:
        // equality against `/` and the home folder alone leaves `/Users`, every account on the
        // machine, as a legal thing to delete.
        guard !pathContains(url.path, FileManager.default.homeDirectoryForCurrentUser.path) else {
            return .failure("That is too much of this Mac to delete.")
        }

        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let isFolder = values?.isDirectory == true
        // Counted before the move, because afterwards there is nothing left to walk, and the answer
        // is only ever used for the sentence.
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

    /// How many entries are inside a folder, itself included, or nothing if it cannot be walked.
    ///
    /// A count rather than a list: nothing wants the names, and holding a hundred thousand of them
    /// to produce one number would be memory this app spends on somebody's terminal instead. `nil`
    /// is answered as a folder holding one thing, so the sentence says what it always says rather
    /// than inventing a figure.
    private static func countInside(_ url: URL) -> Int? {
        guard let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            // The default, spelled out: a link is listed rather than entered, the same rule the
            // delete follows, which is why the two agree on the count.
            options: [],
            // An unreadable folder stops that branch and leaves the walk going, rather than failing
            // the whole count and taking the honest number down with it.
            errorHandler: { _, _ in true }
        ) else { return nil }

        // From one, because the folder itself is going too. A subfolder is counted here and so are
        // its contents, and a link is one thing whatever it points at.
        var count = 1
        while walk.nextObject() != nil { count += 1 }
        return count
    }

    /// Puts a new name on a terminal, if it will take one.
    ///
    /// Two kinds of name, and the difference is the naming rule: one the user typed, which sticks
    /// and is never replaced, and one the terminal earns by being used (the last command run in it)
    /// which holds only until the user names it by hand.
    ///
    /// Clearing the name is the way back: an empty field goes to the last thing that ran there, or
    /// to a number if nothing has.
    private func rename(id: UUID, ownerClientID: String, to requested: String, isManual: Bool) {
        let updated: TerminalSessionInfo? = lock.withLock {
            guard let session = sessions[id], session.ownerClientID == ownerClientID else { return nil }
            let name = sanitizedName(requested)
            if isManual {
                session.manualName = name.isEmpty ? nil : name
            } else {
                // Remembered even while a hand-typed name is in force, so clearing that name has
                // something to fall back to.
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
    /// Counted rather than taken from the count: close the second of three and open another, and
    /// counting hands out a second Terminal 2, which is a visible collision now that the strip of
    /// tabs is the list of terminals.
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

}
