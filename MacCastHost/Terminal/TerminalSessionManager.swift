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
        let name: String
        let process: Process
        let master: FileHandle
        var isRunning = true
        var history = Data()
        var promptTail = ""
        var lastAttention: (kind: TerminalAttentionKind, time: Date)?

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

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var sinks: [String: Sink] = [:]
    private static let maximumHistoryBytes = 512 * 1024

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

        case .create(let requestedName):
            create(ownerClientID: clientID, name: requestedName, sink: sink)

        case .input(let id, let data):
            guard data.count <= 64 * 1024 else {
                sink(.failed(sessionID: id, message: "Terminal input was too large."))
                return
            }
            guard let session = lock.withLock({ sessions[id] }),
                  session.ownerClientID == clientID, session.isRunning else {
                sink(.failed(sessionID: id, message: "That terminal is no longer running."))
                return
            }
            do { try session.master.write(contentsOf: data) }
            catch { sink(.failed(sessionID: id, message: "Could not write to the terminal.")) }

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

    func disconnect(clientID: String) {
        _ = lock.withLock { sinks.removeValue(forKey: clientID) }
    }

    private func create(ownerClientID: String, name requestedName: String, sink: @escaping Sink) {
        let name = normalizedName(requestedName)
        let id = UUID()
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
        send(.closed(sessionID: id), to: ownerClientID)
        terminalLog.notice("closed terminal \(id.uuidString, privacy: .public)")
    }

    private func send(_ event: TerminalEvent, to clientID: String) {
        lock.withLock { sinks[clientID] }?(event)
    }

    private func normalizedName(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = String(trimmed.filter { character in
            !character.isNewline && !character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        }.prefix(40))
        if !safe.isEmpty { return safe }
        return "Terminal \(lock.withLock { sessions.count + 1 })"
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
