import RemoteCore
import SwiftUI

/// Terminals: the events the Mac sends, and the requests the phone makes.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension SessionModel {
    func refreshTerminals() { session?.sendTerminal(.list) }

    /// Opens a shell. It has no name to start with — the Mac numbers it, and the first command
    /// typed into it is what it ends up being called.
    func createTerminal() {
        session?.sendTerminal(.create)
    }

    /// Names a terminal by hand. This is the name it keeps, whatever runs in it next.
    ///
    /// Applied here as well as on the Mac, because the tab under the finger is the one thing
    /// that cannot wait a round trip to show what was just typed into it. The Mac's own answer
    /// arrives a moment later with the name it settled on, which is the same one, tidied.
    func renameTerminal(_ id: UUID, to name: String) {
        // Not for an empty name, which is a request rather than a name: the Mac answers it with
        // the last command run there, and a tab left blank until that arrives would look like
        // the rename had failed.
        if !name.isEmpty, let index = terminals.firstIndex(where: { $0.id == id }) {
            terminals[index].name = name
        }
        session?.sendTerminal(.rename(sessionID: id, name: name))
    }

    /// Which terminal the panel is showing.
    ///
    /// Looking at a terminal does not answer it, so this deliberately leaves its attention mark
    /// alone — a tab that is waiting for a password is still waiting while you read it, and the
    /// mark goes out when the shell says something, which is the only proof it got an answer.
    func selectTerminal(_ id: UUID) {
        selectedTerminalID = id
    }

    func sendTerminalInput(_ text: String, to id: UUID, appendReturn: Bool = true) {
        let suffix = appendReturn ? "\r" : ""
        guard let data = (text + suffix).data(using: .utf8) else { return }
        session?.sendTerminal(.input(sessionID: id, data: data))
        // The command names the terminal it ran in. Whether that name is taken is the Mac's
        // call — a name typed by hand outranks one earned this way.
        session?.sendTerminal(.retitle(sessionID: id, command: text))
        if let index = terminals.firstIndex(where: { $0.id == id }) {
            terminals[index].attention = nil
            terminals[index].failure = nil
        }
        rememberTerminalCommand(text)
        lastSentCommand = text
        lastSentAt = Date()
    }

    /// Takes a command back out of the history when the shell says it did not exist.
    ///
    /// The history is a list of things worth running again, and a typo is the one entry certain
    /// not to work the second time — it is exactly the entry that makes a history list useless,
    /// because it is the one you keep scrolling past.
    ///
    /// Only "command not found", and only for the command just sent: that phrase is the shell
    /// saying it never ran. A command that ran and failed is a command, and dropping those would
    /// leave a history of the parts that happened to work.
    func forgetUnknownCommand(_ data: Data) {
        guard TerminalTextSanitizer.reportsUnknownCommand(data),
              let command = lastSentCommand,
              let sentAt = lastSentAt,
              // A shell's answer arrives in the next read or two. Past that the message belongs
              // to something else — a build log, a script printing its own failures.
              Date().timeIntervalSince(sentAt) < 5
        else { return }

        terminalHistory.removeAll { $0 == command }
        UserDefaults.standard.set(terminalHistory, forKey: Self.terminalHistoryKey)
        lastSentCommand = nil
        lastSentAt = nil
    }

    /// Adds a command to the list the panel offers, and writes it down.
    ///
    /// Newest first and de-duplicated, so a command run twice moves to the top rather than
    /// appearing twice — the list is for finding the one you want, and a log of repeats makes
    /// that harder. Capped, because this is a convenience and not a history file: the Mac's own
    /// shell keeps the real one.
    func rememberTerminalCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = terminalHistory
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > Self.terminalHistoryLimit {
            history.removeLast(history.count - Self.terminalHistoryLimit)
        }
        terminalHistory = history
        UserDefaults.standard.set(history, forKey: Self.terminalHistoryKey)
    }

    static let terminalHistoryKey = "Peering.terminalHistory"
    static let terminalHistoryLimit = 30

    func sendTerminalBytes(_ bytes: [UInt8], to id: UUID) {
        session?.sendTerminal(.input(sessionID: id, data: Data(bytes)))
    }

    func resizeTerminal(_ id: UUID, columns: Int, rows: Int) {
        session?.sendTerminal(.resize(
            sessionID: id,
            columns: UInt16(clamping: columns),
            rows: UInt16(clamping: rows)
        ))
    }

    func closeTerminal(_ id: UUID) {
        session?.sendTerminal(.close(sessionID: id))
    }

    func apply(terminal event: TerminalEvent) {
        switch event {
        case .snapshot(let infos):
            terminals = infos.map {
                RemoteTerminal(id: $0.id, name: $0.name, isRunning: $0.isRunning)
            }
            if selectedTerminalID == nil || !terminals.contains(where: { $0.id == selectedTerminalID }) {
                selectedTerminalID = terminals.first?.id
            }
        case .created(let info):
            terminals.removeAll { $0.id == info.id }
            terminals.append(RemoteTerminal(id: info.id, name: info.name, isRunning: info.isRunning))
            selectedTerminalID = info.id
            append(note: "\(info.name) opened")
        case .renamed(let info):
            guard let index = terminals.firstIndex(where: { $0.id == info.id }) else { return }
            terminals[index].name = info.name
        case .output(let id, let data):
            guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
            forgetUnknownCommand(data)
            terminals[index].output.append(data)
            // The shell said something, so whatever it was waiting on has been answered and
            // whatever went wrong before is no longer what the terminal is doing.
            terminals[index].attention = nil
            terminals[index].failure = nil
            let limit = 512 * 1024
            if terminals[index].output.count > limit {
                terminals[index].output.removeFirst(terminals[index].output.count - limit)
            }
        case .attention(let id, let kind, let message):
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].attention = kind
            }
            selectedTerminalID = id
            append(note: message)
            notifier.terminalNeedsAttention(message, sessionID: id)
        case .exited(let id, let status):
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].isRunning = false
                // A shell that ended by itself is a shell that ended. One that ended carrying a
                // status ended badly, and the tab is where that gets noticed.
                terminals[index].failure = status == 0 ? nil : "Exited with status \(status)"
            }
            append(note: "Terminal exited with status \(status)")
        case .closed(let id):
            let name = terminals.first(where: { $0.id == id })?.name ?? "Terminal"
            terminals.removeAll { $0.id == id }
            if selectedTerminalID == id { selectedTerminalID = terminals.first?.id }
            append(note: "\(name) closed")
        case .failed(let id, let message):
            // A refusal that names a terminal is about that terminal, and it stays on its tab
            // until the terminal works again.
            if let id, let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].failure = message
            }
            append(note: "Terminal: \(message)")
        }
    }

}
