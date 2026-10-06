import Darwin
import Foundation
import RemoteCore
import os

private let terminalLog = Logger(subsystem: "pl.dmq.peering.host", category: "terminal")

final class TerminalSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (TerminalEvent) -> Void

    private final class Session: @unchecked Sendable {
        let id: UUID
        let ownerClientID: String
        let createdAt = Date()
        var name: String
        let process: Process
        let master: FileHandle
        var isRunning = true
        var history = Data()
        /// The shape its screen was last told it is, starting at what ``openpty`` was given.
        var columns = 100
        var rows = 30
        var attentionDetector = TerminalAttentionDetector()
        var finishDetector = TerminalCommandFinishDetector()
        var manualName: String?
        var lastCommand: String?

        init(id: UUID, ownerClientID: String, name: String, process: Process, master: FileHandle) {
            self.id = id
            self.ownerClientID = ownerClientID
            self.name = name
            self.process = process
            self.master = master
        }

        var info: TerminalSessionInfo {
            TerminalSessionInfo(
                id: id,
                name: name,
                isRunning: isRunning,
                columns: columns,
                rows: rows,
                createdAt: createdAt
            )
        }
    }

    /// A file being written, between the request that opened it and the piece that closes it.
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
        let staging: URL
        var handle: FileHandle?
        /// How many bytes have been appended. Touched only under the manager's lock.
        var received = 0
        /// The first thing that went wrong writing to disk, if anything did.
        var failure: String?

        init(ownerClientID: String, path: String, expected: Int, target: URL, staging: URL) {
            self.ownerClientID = ownerClientID
            self.path = path
            self.expected = expected
            self.target = target
            self.staging = staging
        }

        func discard() {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// The one queue every write's disk work happens on.
    private static let writeIO = DispatchQueue(
        label: "pl.dmq.peering.host.write",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var sinks: [String: Sink] = [:]
    private var writes: [WriteKey: PendingWrite] = [:]

    /// The file-browsing scopes that are not shells, by the id the phone made for each.
    private var browsers: [UUID: String] = [:]
    /// How many scopes one client may hold open. More than the one a phone uses, so a bug that
    /// makes a new scope per request is caught rather than unbounded.
    private static let maximumBrowsersPerClient = 4

    var onPushNeeded: (@Sendable (String, String, String) -> Void)?

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
    func registeredPushTokens() -> [String] {
        Array(PushTokenStore.shared.tokensByClient().values)
    }

    func connectedPushClientCount() -> Int {
        let clients = PushTokenStore.shared.tokensByClient().keys
        return lock.withLock { clients.filter { sinks[$0] != nil }.count }
    }
    private static let maximumHistoryBytes = 512 * 1024
    private static let historySlackBytes = 64 * 1024
    private static let maximumSessionsPerClient = 10

    /// One terminal's write to one path.
    private struct WriteKey: Hashable {
        let sessionID: UUID
        let path: String
    }

    /// How large a file this Mac will take from a phone.
    private static let maximumWriteBytes = 2 * 1_073_741_824
    /// How much of a file may travel in one message.
    private static let writeChunkBytes = 32 * 1024

    private static let maximumPreviewBytes = 128 * 1024
    /// How much of a *picture* a preview shows.
    private static let maximumImagePreviewBytes = 8 * 1024 * 1024
    /// How much of a file travels per event. Comfortably inside the 64 KB the control channel
    /// accepts for a request, and small enough that a preview never sits in front of a keystroke
    /// for long.
    private static let previewChunkBytes = 32 * 1024
    private static let binaryProbeBytes = RemoteFileKind.probeBytes

    static func probeAgents(_ reply: @escaping @Sendable ([String]) -> Void) {
        let names = ["claude", "codex", "opencode", "hermes", "gemini", "aider"]
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-l", "-i", "-c", "for c in \(names.joined(separator: " ")); do command -v $c >/dev/null 2>&1 && echo $c; done"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { reply(names); return }
            let deadline = DispatchTime.now() + .seconds(6)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
            if group.wait(timeout: deadline) == .timedOut { process.terminate(); reply(names); return }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let found = output.split(separator: "\n").map { String($0) }.filter { names.contains($0) }
            reply(found)
        }
    }

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
        case .agents:
            Self.probeAgents { sink(.agents(installed: $0)) }

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

        case .startBrowser(let id):
            lock.withLock {
                if browsers.count(where: { $0.value == clientID }) < Self.maximumBrowsersPerClient {
                    browsers[id] = clientID
                }
            }

        case .listDirectory(let id, let path):
            guard canBrowse(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            list(id: id, requested: path, sink: sink)

        case .readFile(let id, let path):
            guard canBrowse(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            read(id: id, path: path, sink: sink)

        case .beginWrite(let id, let path, let totalBytes):
            guard canBrowse(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            beginWrite(id: id, path: path, totalBytes: totalBytes, ownerClientID: clientID, sink: sink)

        case .writeChunk(let id, let path, let data, let isLast):
            guard canBrowse(id, ownerClientID: clientID) else {
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
            guard canBrowse(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            change(id: id, operation: operation, sink: sink)

        case .resize(let id, let columns, let rows):
            guard columns > 0, rows > 0,
                  let session = lock.withLock({ sessions[id] }),
                  session.ownerClientID == clientID else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            guard ioctl(session.master.fileDescriptor, TIOCSWINSZ, &size) != -1 else {
                terminalLog.error("could not resize terminal \(id.uuidString, privacy: .public)")
                return
            }
            // Recorded because a client that lists the sessions is sent this shell's history and
            // has to lay the replay out on the grid those bytes were drawn for: this one.
            lock.withLock {
                session.columns = Int(columns)
                session.rows = Int(rows)
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

    private func liveSession(_ id: UUID, ownerClientID: String) -> Session? {
        lock.withLock {
            guard let session = sessions[id],
                  session.ownerClientID == ownerClientID,
                  session.isRunning else { return nil }
            return session
        }
    }

    /// Whether this client may browse through this id: a shell of its own that is still running,
    /// or a browsing scope it opened with ``TerminalRequest/startBrowser(id:)``.
    private func canBrowse(_ id: UUID, ownerClientID: String) -> Bool {
        if liveSession(id, ownerClientID: ownerClientID) != nil { return true }
        return lock.withLock { browsers[id] == ownerClientID }
    }

    func disconnect(clientID: String) {
        // Whatever it was in the middle of writing goes with it: an unfinished transfer is not a
        // file waiting to be resumed, because the client that would claim it is the one that has
        // just gone.
        let abandoned = lock.withLock { () -> [PendingWrite] in
            let mine = writes.values.filter { $0.ownerClientID == clientID }
            writes = writes.filter { $0.value.ownerClientID != clientID }
            browsers = browsers.filter { $0.value != clientID }
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
    private static let zshFinishHookLine =
        #"zmodload zsh/datetime 2>/dev/null; __mc_preexec(){ __mc_t0=$EPOCHREALTIME; __mc_cmd=$1; }; __mc_precmd(){ local __mc_s=$?; if [[ -n $__mc_t0 ]]; then local __mc_d=$(( (EPOCHREALTIME - __mc_t0) * 1000 )); __mc_d=${__mc_d%.*}; if (( __mc_d >= 5000 )); then printf '\033]9999;%s;%s;%s\007' "$__mc_d" "$__mc_s" "$(printf %s "$__mc_cmd" | base64 | tr -d '\n')"; fi; unset __mc_t0; fi }; precmd_functions+=(__mc_precmd); preexec_functions+=(__mc_preexec)"#

    private static let bashFinishHookLine =
        #"export HISTTIMEFORMAT="%s "; set -o history; __mc_last=""; __mc_precmd(){ local __mc_s=$?; local __mc_line; __mc_line=$(history 1); local __mc_ts=$(printf '%s\n' "$__mc_line" | awk '{print $2}'); local __mc_cmd=$(printf '%s\n' "$__mc_line" | awk '{$1="";$2="";print}' | sed 's/^  *//'); local __mc_now=$(date +%s); local __mc_d=$(( (__mc_now - __mc_ts) * 1000 )); if [ "$__mc_line" != "$__mc_last" ] && [ "$__mc_d" -ge 5000 ]; then printf '\033]9999;%s;%s;%s\007' "$__mc_d" "$__mc_s" "$(printf %s "$__mc_cmd" | base64 | tr -d '\n')"; fi; __mc_last="$__mc_line"; }; PROMPT_COMMAND="__mc_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#

    /// Points zsh at a directory of wrapper dotfiles that source the real ones and then add the
    /// finish hook, so the hook arrives as configuration and not as typed input.
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

    private enum PreviewOutcome {
        case contents(Data, kind: RemoteFileKind, totalBytes: Int)
        case failure(String)
    }

    private func list(id: UUID, requested: String?, sink: @escaping Sink) {
        // Absolute paths only: a relative one resolves against this process's working directory
        // rather than the shell's, which is the directory the user believes they are looking at.
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.browseFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can open."
            ))
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            switch DirectoryListing.entries(in: directory) {
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

    private func read(id: UUID, path: String, sink: @escaping Sink) {
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
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let key = WriteKey(sessionID: id, path: url.path)
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

    private func write(
        id: UUID,
        path: String,
        data: Data,
        isLast: Bool,
        ownerClientID: String,
        sink: @escaping Sink
    ) {
        let key = WriteKey(sessionID: id, path: URL(fileURLWithPath: path).standardizedFileURL.path)
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

    /// A file's contents, bounded: its text if it is text, and its bytes if it is a picture.
    private static func contents(of url: URL) -> PreviewOutcome {
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
        guard looked == 0 else { return .failure(DirectoryListing.message(forErrno: failure)) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .failure("That is not a file, so there is nothing to show here.")
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { return .failure(DirectoryListing.message(for: error)) }
        defer { try? handle.close() }

        let totalBytes = Int(info.st_size)
        var data = Data()
        var kind = RemoteFileKind.text
        do {
            // A read may return less than it was asked for, so it is asked again until the cap or
            // the end of the file.
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
            return .failure(DirectoryListing.message(for: error))
        }

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
    private static func changeMessage(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteFileExistsError:
                return "Something with that name is already there."
            case NSFileNoSuchFileError:
                return "That is no longer there."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return DirectoryListing.message(forErrno: EPERM)
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
            case ENAMETOOLONG:
                return "That name is too long for this Mac."
            default:
                return DirectoryListing.message(forErrno: Int32(error.code))
            }
        }
        return error.localizedDescription
    }

    // MARK: - Changing the tree

    private func change(id: UUID, operation: RemoteFileOperation, sink: @escaping Sink) {
        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

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
    private static func create(at url: URL, kind: RemoteEntryKind) -> ChangeOutcome {
        let name = url.lastPathComponent
        guard RemoteFileName.isValid(name) else {
            return .failure("That is not a name a file can have.")
        }
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
            let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                return .failure(changeMessage(for: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )))
            }
            Darwin.close(descriptor)
            return .done("created file \(name)")
        }
    }

    /// A new name for something already in a folder.
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
    private static func delete(at url: URL) -> ChangeOutcome {
        let name = url.lastPathComponent
        // Guard rails against a bug rather than a user: no row in the browser can name the folder
        // you are standing in. A client that has been got at can.
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
    private static func countInside(_ url: URL) -> Int? {
        guard let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }

        // From one, because the folder itself is going too. A subfolder is counted here and so are
        // its contents, and a link is one thing whatever it points at.
        var count = 1
        while walk.nextObject() != nil { count += 1 }
        return count
    }

    /// Puts a new name on a terminal, if it will take one.
    private func rename(id: UUID, ownerClientID: String, to requested: String, isManual: Bool) {
        let updated: TerminalSessionInfo? = lock.withLock {
            guard let session = sessions[id], session.ownerClientID == ownerClientID else { return nil }
            let name = sanitizedName(requested)
            if isManual {
                session.manualName = name.isEmpty ? nil : name
            } else {
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
    private func unusedTerminalName(excluding excluded: Session? = nil) -> String {
        let taken = Set(sessions.values.filter { $0 !== excluded }.map(\.name))
        var number = 1
        while taken.contains("Terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }

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
