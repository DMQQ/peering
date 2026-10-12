import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    func refreshTerminals() { wire?.sendTerminal(.list) }

    static func installedAgentsKey(_ hostName: String) -> String { "Peering.installedAgents.\(hostName)" }

    var knownInstalledAgents: Set<String>? {
        if let installedAgents { return installedAgents }
        guard hostSupportsAgentList, let hostName,
              let saved = UserDefaults.standard.stringArray(forKey: Self.installedAgentsKey(hostName))
        else { return nil }
        return Set(saved)
    }

    func refreshAgents() {
        guard hostSupportsAgentList else { return }
        wire?.sendTerminal(.agents)
    }

    func openFileScope() {
        guard hostSupportsFileBrowser else { return }
        wire?.sendTerminal(.startBrowser(id: browserID))
    }

    func createTerminal() {
        createTerminal(inDirectory: nil)
    }

    /// **The folder is a `cd`, not a flag.** The wire's create request has no directory, and it
    /// does not need one: a shell opens in the login folder and is sent one line, exactly as a
    /// browser sends `cd` when a folder is opened. Sent as bytes rather than through
    /// ``sendTerminalInput(_:to:)`` so it does not name the shell "cd" or land in the command
    /// history — the same reasoning ``navigate(to:in:)`` records.
    func createTerminal(inDirectory path: String?) {
        pendingTerminalDirectory = path
        wire?.sendTerminal(.create)
    }

    /// **A shell of its own rather than the one the browser is sitting on.** That shell is the one
    /// the user has been typing into, and a file that prints for a minute or waits on a prompt
    /// should not take it over, nor should running one quietly change the directory it was in.
    /// The cost is one round trip between the tap and the output, which is what ``pendingRun`` is.
    func runInNewTerminal(_ command: String) {
        pendingRun = command
        createTerminal()
    }

    func renameTerminal(_ id: UUID, to name: String) {
        // Not for an empty name, which is a request rather than a name: the Mac answers it with
        // the last command run there, and a tab left blank until that arrives would look like
        // the rename had failed.
        if !name.isEmpty, let index = terminals.firstIndex(where: { $0.id == id }) {
            terminals[index].name = name
        }
        wire?.sendTerminal(.rename(sessionID: id, name: name))
    }

    /// Looking at a terminal does not answer it, so this deliberately leaves its attention mark
    /// alone — a tab that is waiting for a password is still waiting while you read it, and the
    /// mark goes out when the shell says something, which is the only proof it got an answer.
    func selectTerminal(_ id: UUID) {
        selectedTerminalID = id
    }

    func sendTerminalInput(_ text: String, to id: UUID, appendReturn: Bool = true) {
        let suffix = appendReturn ? "\r" : ""
        guard let data = (text + suffix).data(using: .utf8) else { return }
        guard sendInChunks(data, to: id) else { return }
        wire?.sendTerminal(.retitle(sessionID: id, command: String(text.prefix(200))))
        if let index = terminals.firstIndex(where: { $0.id == id }) {
            terminals[index].attention = nil
            terminals[index].failure = nil
        }
        model.rememberTerminalCommand(text)
        lastSentCommand = text
        lastSentAt = Date()
    }

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

        model.removeFromTerminalHistory(command)
        lastSentCommand = nil
        lastSentAt = nil
    }

    func sendTerminalBytes(_ bytes: [UInt8], to id: UUID) {
        sendInChunks(Data(bytes), to: id)
    }

    /// One control message is capped at 64 KB, so a long paste goes as several inputs; the stream keeps them in order.
    @discardableResult
    private func sendInChunks(_ data: Data, to id: UUID) -> Bool {
        guard ControlTextPolicy.verdict(forTerminalInput: data) == .fits else {
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].failure = String(localized: "That is too much to paste into a terminal at once.")
            }
            return false
        }
        for chunk in ControlTextPolicy.terminalChunks(data) {
            wire?.sendTerminal(.input(sessionID: id, data: chunk))
        }
        return true
    }

    /// **Rows only ever grow, and that is what keeps the keyboard out of a terminal.** Opening it
    /// shortens the panel's log, which is a change to this app's chrome and not to the shell's
    /// screen: a resize makes the far end redraw everything it has, and a full-screen program
    /// redrawing itself is the one thing the emulator on this end is worst at. The log scrolls
    /// inside the taller screen instead, which loses nothing, since it follows the bottom of the
    /// output and the bottom of the output is where the shell's cursor is.
    func resizeTerminal(_ id: UUID, columns: Int, rows: Int) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        let rows = max(terminals[index].rows, rows)
        #if DEBUG
        TerminalTrace.write(["k": "r", "id": id.uuidString, "c": columns, "r": rows, "was": [terminals[index].columns, terminals[index].rows], "n": terminals[index].output.count])
        #endif
        terminals[index].columns = columns
        terminals[index].rows = rows
        // Sent even when it matches what this end believes, because the Mac's PTY is not this
        // end's state: it keeps the size it was given the last time a panel sized it, and a panel
        // that opens at the shape it closed at would otherwise never correct it. The ioctl is cheap
        // and idempotent, and a comparison here was not.
        wire?.sendTerminal(.resize(
            sessionID: id,
            columns: UInt16(clamping: columns),
            rows: UInt16(clamping: rows)
        ))
    }

    func closeTerminal(_ id: UUID) {
        wire?.sendTerminal(.close(sessionID: id))
    }
}
