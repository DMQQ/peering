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

    // MARK: - Browsing

    /// The most of a file this side keeps.
    ///
    /// The Mac caps a preview well below this and the cap here is not the one that binds; it is
    /// here so that the limit on what arrives is a decision this end made rather than one it
    /// inherits — a client that grows to whatever it is sent is one that runs out of memory on a
    /// Mac's mistake.
    static let previewByteLimit = 1024 * 1024

    /// The folder a terminal's browser is showing, and `nil` while that is still the Mac's home
    /// folder with its path not yet resolved.
    func browsingPath(for id: UUID) -> String? { browsingPaths[id] }

    /// Points a terminal's browser at a folder, before asking for it.
    func setBrowsingPath(_ path: String?, for id: UUID) { browsingPaths[id] = path }

    /// Asks the Mac for a folder's contents. `nil` is its home folder, which is where a browser
    /// starts: the shell's own working directory is not something this side is told, and home is
    /// the one answer that is right often enough to open on.
    func listDirectory(_ path: String?, sessionID id: UUID) {
        let key = RemoteDirectoryKey(terminalID: id, path: path)
        pendingDirectories.insert(key)
        browseFailures.removeValue(forKey: key)
        session?.sendTerminal(.listDirectory(sessionID: id, path: path))
    }

    /// Asks the Mac to read a file, replacing whatever was being previewed.
    func previewFile(_ path: String, sessionID id: UUID) {
        filePreview = RemoteFilePreview(terminalID: id, path: path)
        session?.sendTerminal(.readFile(sessionID: id, path: path))
    }

    func closePreview() {
        filePreview = nil
    }

    func directory(_ path: String?, sessionID id: UUID) -> RemoteDirectory? {
        directories[RemoteDirectoryKey(terminalID: id, path: path)]
    }

    func isLoadingDirectory(_ path: String?, sessionID id: UUID) -> Bool {
        pendingDirectories.contains(RemoteDirectoryKey(terminalID: id, path: path))
    }

    func browseFailure(_ path: String?, sessionID id: UUID) -> String? {
        browseFailures[RemoteDirectoryKey(terminalID: id, path: path)]
    }

    /// Stops waiting on anything this terminal was asked for.
    ///
    /// For the answers that arrive as an ordinary failure rather than as a listing — a Mac that
    /// will not read a folder because the shell behind it has ended. A request nothing will answer
    /// must not leave a panel spinning at a Mac that has already said no.
    func clearPendingBrowsing(for id: UUID) {
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
    }

    /// Everything remembered about a terminal's browsing, dropped with the terminal it belongs to.
    func forgetBrowsing(for id: UUID) {
        directories = directories.filter { $0.key.terminalID != id }
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
        browseFailures = browseFailures.filter { $0.key.terminalID != id }
        browsingPaths.removeValue(forKey: id)
        if filePreview?.terminalID == id { filePreview = nil }
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
        case .directory(let id, let path, let entries, let truncated):
            let key = RemoteDirectoryKey(terminalID: id, path: path)
            directories[key] = RemoteDirectory(entries: entries, isTruncated: truncated)
            pendingDirectories.remove(key)
            browseFailures.removeValue(forKey: key)
            // The one answer that can move a browser: the first request of one names no path, and
            // this is where the Mac's home folder becomes a path the breadcrumbs can be built from
            // and the next request can name. Every other answer is to a folder already settled on.
            if browsingPaths[id] == nil { browsingPaths[id] = path }
            // A request that named no path — the first one a browser makes — is answered with the
            // path it resolved to, so the entry it was waiting under is cleared alongside.
            let unresolved = RemoteDirectoryKey(terminalID: id, path: nil)
            pendingDirectories.remove(unresolved)
            browseFailures.removeValue(forKey: unresolved)

        case .browseFailure(let id, let path, let message):
            let key = RemoteDirectoryKey(terminalID: id, path: path)
            pendingDirectories.remove(key)
            browseFailures[key] = message
            // Same move as above, and it is the whole reason it is done only for a request that is
            // actually outstanding: a folder that fails to open later must not land this on the
            // home listing's entry as well.
            let unresolved = RemoteDirectoryKey(terminalID: id, path: nil)
            if pendingDirectories.remove(unresolved) != nil {
                browseFailures[unresolved] = message
            }

        case .fileContents(let id, let path, let offset, let totalBytes, let data, let isLast):
            guard var preview = filePreview, preview.terminalID == id, preview.path == path else {
                // A piece of a file nobody is looking at any more, or of one opened in another
                // terminal since. Dropped rather than shown under the wrong name.
                return
            }
            // Pieces are joined before they are decoded, because a cut can fall inside a
            // character — see ``TerminalEvent/fileContents``. Past the cap they are dropped
            // instead, so a Mac that one day sends more than it promised cannot grow this phone's
            // memory by the size of a file; the size on disk is still what says it was cut short.
            if offset + data.count <= Self.previewByteLimit {
                preview.data.append(data)
            }
            preview.totalBytes = totalBytes
            preview.isComplete = isLast
            filePreview = preview

        case .closed(let id):
            let name = terminals.first(where: { $0.id == id })?.name ?? "Terminal"
            terminals.removeAll { $0.id == id }
            if selectedTerminalID == id { selectedTerminalID = terminals.first?.id }
            forgetBrowsing(for: id)
            append(note: "\(name) closed")
        case .failed(let id, let message):
            // A refusal that names a terminal is about that terminal, and it stays on its tab
            // until the terminal works again.
            if let id, let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].failure = message
            }
            // A terminal that is gone takes its outstanding browse requests with it: a panel left
            // waiting on a listing that is never coming has no way back on its own.
            if let id { clearPendingBrowsing(for: id) }
            append(note: "Terminal: \(message)")
        }
    }

}

/// Which listing a remembered one is: one terminal on this phone, one folder at the other end.
///
/// The path is the one that was *asked for*, not the one that came back, so the first request of a
/// browser — the one that names no path and is answered with the home folder of the machine behind
/// the shell — has an entry of its own for as long as it is outstanding.
///
/// Shared with the SSH browser, which has the same two things to remember and the same question to
/// ask about them. One type rather than two identical ones: a terminal on this phone and a path on
/// the machine it is talking to is what this is, whichever machine that turns out to be.
struct RemoteDirectoryKey: Hashable {
    let terminalID: UUID
    let path: String?
}

/// A folder's contents, as the Mac sent them.
struct RemoteDirectory: Equatable {
    var entries: [RemoteDirectoryEntry]
    /// The Mac had more to send than it sends in one listing.
    var isTruncated: Bool
}

/// A file being shown, in the state it has reached.
struct RemoteFilePreview: Equatable {
    let terminalID: UUID
    let path: String
    var totalBytes = 0
    /// The pieces received so far, still joined rather than decoded: a chunk boundary can fall
    /// inside a character, so the text is only read out once the whole of it is here.
    var data = Data()
    var isComplete = false

    var text: String { String(decoding: data, as: UTF8.self) }

    /// Whether what is here is the beginning of a file rather than the whole of one.
    ///
    /// Only asked once the last piece has arrived. Half a file is not a truncation, it is a file
    /// still coming, and a panel that said "truncated" while it was still filling would say it
    /// about every preview that worked.
    ///
    /// **The reader's own answer wins when there is one.** The arithmetic below cannot see
    /// everything the reader can: a server that reports no file size leaves `totalBytes` equal to
    /// what arrived, so the comparison says "the whole file" about one that was cut off at the cap.
    /// Only the side that stopped reading knows it stopped, so when it says so that is the answer —
    /// and this is a value somebody's file depends on, because an edit is written back whole.
    var reportedTruncation: Bool?

    var isTruncated: Bool {
        reportedTruncation ?? (isComplete && data.count < totalBytes)
    }
}
