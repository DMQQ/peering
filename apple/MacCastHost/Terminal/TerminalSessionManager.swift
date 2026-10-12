import Darwin
import Foundation
import MacCastKit
import RemoteCore
import os

let terminalLog = Logger(subsystem: "pl.dmq.peering.host", category: "terminal")

final class TerminalSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (TerminalEvent) -> Void

    /// The one queue every write's disk work happens on.
    static let writeIO = DispatchQueue(
        label: "pl.dmq.peering.host.write",
        qos: .userInitiated
    )

    let lock = NSLock()
    var sessions: [UUID: Session] = [:]
    var sinks: [String: Sink] = [:]
    var writes: [WriteKey: PendingWrite] = [:]

    /// The file-browsing scopes that are not shells, by the id the phone made for each.
    var browsers: [UUID: String] = [:]
    /// How many scopes one client may hold open. More than the one a phone uses, so a bug that
    /// makes a new scope per request is caught rather than unbounded.
    static let maximumBrowsersPerClient = 4

    var onPushNeeded: (@Sendable (String, String, String) -> Void)?

    /// Where a phone is, so a push goes to one that is away or backgrounded. Set once before any phone connects.
    var presence: (@Sendable (String) -> PhonePresence)?

    /// The tokens of phones that are not looking at the app: no connection, or one that left the foreground.
    func allPushTokens() -> [String] {
        PushTokenStore.shared.tokensByClient().compactMap { clientID, token in
            PushPolicy.shouldPush(presence: presence?(clientID) ?? .gone, hasToken: true) ? token : nil
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
    static let maximumHistoryBytes = 512 * 1024
    static let historySlackBytes = 64 * 1024
    static let maximumSessionsPerClient = 10

    /// How large a file this Mac will take from a phone.
    static let maximumWriteBytes = 2 * 1_073_741_824
    /// How much of a file may travel in one message.
    static let writeChunkBytes = 32 * 1024

    static let maximumPreviewBytes = 128 * 1024
    /// How much of a *picture* a preview shows.
    static let maximumImagePreviewBytes = 8 * 1024 * 1024
    /// How much of a file travels per event. Comfortably inside the 64 KB the control channel
    /// accepts for a request, and small enough that a preview never sits in front of a keystroke
    /// for long.
    static let previewChunkBytes = 32 * 1024
    static let binaryProbeBytes = RemoteFileKind.probeBytes

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

        case .readRange(let id, let path, let offset):
            guard canBrowse(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            readRange(id: id, path: path, offset: offset, sink: sink)

        case .archiveFolder(let id, let path):
            guard canBrowse(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            archiveFolder(id: id, path: path, sink: sink)

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

    func liveSession(_ id: UUID, ownerClientID: String) -> Session? {
        lock.withLock {
            guard let session = sessions[id],
                  session.ownerClientID == ownerClientID,
                  session.isRunning else { return nil }
            return session
        }
    }

    /// Whether this client may browse through this id: a shell of its own that is still running,
    /// or a browsing scope it opened with ``TerminalRequest/startBrowser(id:)``.
    func canBrowse(_ id: UUID, ownerClientID: String) -> Bool {
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



}
