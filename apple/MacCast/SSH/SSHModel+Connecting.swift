import Foundation
import MacCastKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    /// A session that fails then closes emits both events, and the first is the fact worth keeping.
    private func record(_ terminal: SSHTerminal, outcome: SSHConnectionRecord.Outcome) {
        guard !terminal.isRecorded else { return }
        terminal.isRecorded = true

        history.insert(
            SSHConnectionRecord(
                hostID: terminal.host.id,
                name: terminal.host.displayName,
                detail: terminal.host.detail,
                startedAt: terminal.startedAt,
                endedAt: Date(),
                outcome: outcome
            ),
            at: 0
        )
        if history.count > SSHConnectionHistoryStore.limit {
            history.removeLast(history.count - SSHConnectionHistoryStore.limit)
        }
        historyStore.save(history)
    }

    @discardableResult
    func open(_ host: SSHHost, credential: SSHCredential, remember: Bool) -> SSHTerminal {
        Analytics.featureUsed(.sshConnected)
        SessionNotifier.shared.prepareForFirstConnect()
        if remember {
            credentials.save(credential, for: host.id)
        }

        let terminalID = UUID()
        let session = SSHSession(host: host, credential: credential, knownHosts: knownHosts) { [weak self] prompt in
            await self?.ask(about: prompt, owner: terminalID) ?? false
        }

        let terminal = SSHTerminal(id: terminalID, host: host, session: session, credential: credential)
        terminals.append(terminal)
        selectedTerminalID = terminal.id
        hostSessions[host.id, default: []].append(session)
        syncTerminalActivity()

        // Stamped only once a shell opened: the list says what worked, not what was tried.
        Task { @MainActor [weak self] in
            for await event in session.events {
                switch event {
                case .connected:
                    terminal.setPhase(.live)
                    self?.markConnected(host)
                    self?.syncTerminalActivity()
                    // After `.live` and in its own task, so the shell is usable the moment it opens rather than once every listener has bound.
                    if let self {
                        Task { await self.startEnabledForwards(on: host) }
                    }
                case .output(let data):
                    if let attention = terminal.append(data) {
                        let reason = attention == .password ? String(localized: "a password") : String(localized: "your response")
                        SessionNotifier.shared.terminalNeedsAttention(
                            String(localized: "SSH “\(terminal.title)” is waiting for \(reason)."),
                            sessionID: terminal.id,
                            name: terminal.title,
                            isSSH: true
                        )
                    }
                case .outputDropped:
                    let notice = String(localized: "[Output was dropped because the screen could not keep up.]")
                    _ = terminal.append(Data("\r\n\(notice)\r\n".utf8))
                case .failed(let error):
                    let reason = Self.describe(error)
                    terminal.setPhase(.ended(reason))
                    self?.clearPendingBrowsing(for: terminal.id)
                    self?.record(terminal, outcome: .failed(reason))
                    self?.syncTerminalActivity()
                    await self?.endForwards(for: terminal)
                case .closed:
                    if case .ended = terminal.phase {} else { terminal.setPhase(.ended(nil)) }
                    self?.clearPendingBrowsing(for: terminal.id)
                    self?.syncTerminalActivity()
                    await self?.endForwards(for: terminal)
                    // `.closed` arrives whether the shell was live or failed, so one case covers the user closing and the server hanging up. A failed attempt never reports `.connected`, as `record(_:outcome:)` keeps the first answer.
                    self?.record(terminal, outcome: .connected)
                }
            }
        }

        session.connect()
        return terminal
    }

    /// Asks for the password only when none is stored; the lock sheet and the connection log arrive here too.
    func connect(_ host: SSHHost) {
        if let credential = storedCredential(for: host) {
            open(host, credential: credential, remember: false)
        } else {
            pendingPasswordHost = host
        }
    }

    func requestClose(_ terminal: SSHTerminal) {
        if terminal.hasSomethingToLose {
            pendingClose = terminal
        } else {
            close(terminal)
        }
    }

    func close(_ terminal: SSHTerminal) {
        terminal.session.close()
        refuseKeyPrompts(ownedBy: terminal.id)
        forgetBrowsing(for: terminal.id)
        terminals.removeAll { $0.id == terminal.id }
        if selectedTerminalID == terminal.id {
            selectedTerminalID = terminals.last?.id
        }
        syncTerminalActivity()
        // Ended here as well as on `.closed`: a listener that outlived its shell is a port open with nothing behind it, so connections through it hang.
        Task { await self.endForwards(for: terminal) }
    }

    /// Two shells on one server share one set of forwards, so stopping them whenever any shell ended would let the second tab kill the first's tunnels.
    private func endForwards(for terminal: SSHTerminal) async {
        let hostID = terminal.host.id
        hostSessions[hostID]?.removeAll { $0 === terminal.session }
        let stillOpen = hostSessions[hostID]?.contains { session in
            terminals.contains { $0.session === session }
        } ?? false
        guard !stillOpen else { return }

        await stopForwards(on: hostID)
        hostSessions.removeValue(forKey: hostID)
    }

    func send(_ data: Data, to terminal: SSHTerminal) {
        terminal.userDidRespond()
        terminal.session.send(data)
    }

    /// Both ends: the server, so the program lays out for the right columns, and the local emulator, so the grid has the same shape.
    func resize(columns: Int, rows: Int, for terminal: SSHTerminal) {
        guard columns != terminal.columns || rows != terminal.rows else { return }
        terminal.columns = columns
        terminal.rows = rows
        terminal.session.resize(columns: columns, rows: rows)
    }

    private func markConnected(_ host: SSHHost) {
        var updated = host
        updated.lastConnectedAt = Date()
        save(updated)
    }
}
