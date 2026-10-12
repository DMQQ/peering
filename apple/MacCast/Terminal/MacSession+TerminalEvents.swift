import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    /// How much a shell's output may run past its limit before the tail is rebuilt, so the copy is
    /// paid once per this many bytes rather than once per chunk.
    static let outputSlack = 64 * 1024

    func refreshTerminalCards() {
        terminalCardsTask?.cancel()
        terminalCardsTask = nil
        let cards = terminals.map(TerminalCardDigest.init)
        if cards != terminalCards { terminalCards = cards }
    }

    func scheduleTerminalCards() {
        guard terminalCardsTask == nil else { return }
        terminalCardsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.refreshTerminalCards()
        }
    }

    func apply(terminal event: TerminalEvent) {
        defer {
            if case .output = event { scheduleTerminalCards() } else { refreshTerminalCards() }
        }
        switch event {
        case .agents(let installed):
            installedAgents = Set(installed)
            if let hostName { UserDefaults.standard.set(installed, forKey: Self.installedAgentsKey(hostName)) }

        case .snapshot(let infos):
            // The output each of these sessions had is gone with the old entries and arrives again
            // in the listing's own replay; the *shape* of their screens must not go with it, since
            // that replay is laid out on it. See ``RemoteTerminal/from(_:remembering:)``.
            terminals = RemoteTerminal.from(infos, remembering: terminals)
            if selectedTerminalID == nil || !terminals.contains(where: { $0.id == selectedTerminalID }) {
                selectedTerminalID = terminals.first?.id
            }
        case .created(let info):
            terminals.removeAll { $0.id == info.id }
            terminals.append(RemoteTerminal(info))
            selectedTerminalID = info.id
            newTerminalID = info.id
            append(note: String(localized: "\(info.name) opened"))
            // The shell a Run button was waiting for. Taken here rather than left set, because the
            // id it needs did not exist until this line — see ``pendingRun``. Through
            // ``sendTerminalInput(_:to:)`` rather than the raw send, so the tab is named after the
            // file it is running and the command lands in the history like any other.
            // The folder a new shell was asked to open in, sent as its first line. Raw bytes, so
            // it does not re-title the shell or fill the command history with a `cd`.
            if let directory = pendingTerminalDirectory {
                pendingTerminalDirectory = nil
                TerminalFolders.record(directory, for: info.id)
                sendTerminalBytes(Array("cd -- \(ShellPath.quoted(directory))\r".utf8), to: info.id)
            }
            if let command = pendingRun {
                pendingRun = nil
                sendTerminalInput(command, to: info.id)
                if let agent = TerminalAgent.all.first(where: { $0.command == command }) {
                    AgentHistory.attach(terminalID: info.id, toNewest: agent.id)
                }
            }
        case .renamed(let info):
            guard let index = terminals.firstIndex(where: { $0.id == info.id }) else { return }
            terminals[index].name = info.name
        case .output(let id, let data):
            guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
            forgetUnknownCommand(data)
            #if DEBUG
            TerminalTrace.write(["k": "d", "id": id.uuidString, "h": data.map { String(format: "%02x", $0) }.joined()])
            #endif
            terminals[index].output.append(data)
            terminals[index].attention = nil
            terminals[index].failure = nil
            let limit = 512 * 1024
            // Rebound rather than cut with `removeFirst`, which moves `Data`'s start index instead of
            // compacting and so keeps the whole stream alive behind a buffer that looks its limit. The
            // copy is why it is paid once per slack rather than per chunk.
            if terminals[index].output.count > limit + Self.outputSlack {
                let dropped = terminals[index].output.count - limit
                terminals[index].output = Data(terminals[index].output.dropFirst(dropped))
                terminals[index].screenFeed.discardFront(dropped)
            }
        case .attention(let id, let kind, let message):
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].attention = kind
            }
            selectedTerminalID = id
            append(note: message)
            // A Mac with this phone's APNs token pushes the alert even while the control channel
            // remains connected in Picture in Picture. Only make a local banner when there is no
            // token to push to, or the same event would normally appear twice.
            if model.notifier.shouldAnnounceTerminal(hostPushesWhileConnected: hostPushesTerminalAlertsWhileConnected) {
                model.notifier.terminalNeedsAttention(
                    message,
                    sessionID: id,
                    name: terminals.first { $0.id == id }?.name,
                    macName: hostName
                )
            }
        case .commandFinished(let id, let command, let duration, _):
            let named = command.map { "\u{201C}\($0)\u{201D}" }
                ?? terminals.first(where: { $0.id == id }).map { String(localized: "Terminal \u{201C}\($0.name)\u{201D}") }
                ?? String(localized: "Terminal")
            let message = String(localized: "\(named) finished\(TerminalCommandFinishDetector.durationSuffix(duration)).")
            append(note: message)
            if model.notifier.shouldAnnounceTerminal(hostPushesWhileConnected: hostPushesTerminalAlertsWhileConnected) {
                model.notifier.terminalFinishedWork(
                    message,
                    sessionID: id,
                    name: terminals.first { $0.id == id }?.name,
                    macName: hostName
                )
            }
        case .exited(let id, let status):
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].isRunning = false
                terminals[index].failure = status == 0 ? nil : String(localized: "Exited with status \(status)")
            }
            append(note: String(localized: "Terminal exited with status \(status)"))
        case .directory(let id, let path, let entries, let truncated):
            let key = RemoteDirectoryKey(terminalID: id, path: path)
            directories[key] = RemoteDirectory(entries: entries, isTruncated: truncated)
            pendingDirectories.remove(key)
            browseFailures.removeValue(forKey: key)
            // The one answer that can move a browser: the first request of one names no path, and
            // this is where the Mac's home folder becomes a path the breadcrumbs can be built from
            // and the next request can name. Every other answer is to a folder already settled on.
            if browsingPaths[id] == nil { browsingPaths[id] = path }
            let unresolved = RemoteDirectoryKey(terminalID: id, path: nil)
            pendingDirectories.remove(unresolved)
            browseFailures.removeValue(forKey: unresolved)

        case .fileRange(let id, let path, let offset, let totalBytes, let data):
            apply(fileRange: id, path: path, offset: offset, totalBytes: totalBytes, data: data)

        case .archiveReady(let id, let folder, let archivePath, _):
            apply(archiveReady: id, folder: folder, archivePath: archivePath)

        case .transferFailure(let id, let path, let message):
            apply(transferFailure: id, path: path, message: message)

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

        case .fileContents(let id, let path, let kind, let offset, let totalBytes, let data, let isLast):
            guard var preview = filePreview, preview.terminalID == id, preview.path == path else {
                return
            }
            preview.kind = kind
            // Pieces are joined before they are decoded, because a cut can fall inside a
            // character — see ``TerminalEvent/fileContents``. Past the cap they are dropped
            // instead, so a Mac that one day sends more than it promised cannot grow this phone's
            // memory by the size of a file; the size on disk is still what says it was cut short.
            if offset + data.count <= Self.previewByteLimit(for: kind) {
                preview.data.append(data)
            }
            preview.totalBytes = totalBytes
            preview.isComplete = isLast
            filePreview = preview

        case .wroteFile(let id, let path, let totalBytes):
            // Matched on the path as well as the terminal, because the Mac names the file it wrote
            // and the panel may have moved on since: a save that lands after another file has been
            // opened must not put its contents under the second one's name.
            guard let write = writes[id], write.path == path else { break }
            writes.removeValue(forKey: id)
            saveFailures.removeValue(forKey: id)
            uploadFailures.removeValue(forKey: id)
            switch write.door {
            case .save:
                previewFile(path, sessionID: id)
            case .upload:
                // **Unless a folder is being sent through this shell**, in which case this is one
                // file of many and the question belongs to the end of the run: two hundred files
                // would otherwise be two hundred listings of the same directory.
                if folderUploads[id]?.isRunning != true {
                    listDirectory((path as NSString).deletingLastPathComponent, sessionID: id)
                }
            }
            finishFolderEntry(path: path, outcome: .done, sessionID: id)
            let written = path.split(separator: "/").last.map(String.init) ?? path
            append(note: String(localized: "Wrote \(written) (\(totalBytes.formatted(.byteCount(style: .file))))"))

        case .writeFailure(let id, let path, let message):
            guard let write = writes[id], write.path == path else { break }
            writes.removeValue(forKey: id)
            switch write.door {
            case .save: saveFailures[id] = message
            case .upload:
                // **Not filed as the shell's upload failure while a folder is running.** That
                // sentence is drawn over the folder as a whole, and one unreadable file inside a
                // folder is not a failure of the folder: it is one entry's outcome, which is where
                // it goes instead, and the run carries on to the next one.
                if folderUploads[id]?.isRunning != true { uploadFailures[id] = message }
            }
            finishFolderEntry(path: path, outcome: .failed(message), sessionID: id)
            append(note: String(localized: "Terminal: \(message)"))

        case .fileOperationDone(let id, let path, let note):
            guard let change = changes[id], change.path == path else { break }
            changes.removeValue(forKey: id)
            changeFailures.removeValue(forKey: id)
            finish(change, sessionID: id)
            finishFolderEntry(path: path, outcome: .done, sessionID: id)
            append(note: String(localized: "Terminal: \(note)"))

        case .fileOperationFailure(let id, let path, let message):
            guard let change = changes[id], change.path == path else { break }
            changes.removeValue(forKey: id)
            changeFailures[id] = message
            finishFolderEntry(path: path, outcome: .failed(message), sessionID: id)
            // A rename that did not land may still have been the one that emptied a folder, and a
            // delete that did not land certainly was not. Re-asking is cheap and is the only way to
            // know which: nothing here can tell what the disk looks like now.
            if case .delete = change.operation {
                listDirectory((path as NSString).deletingLastPathComponent, sessionID: id)
            }

        case .closed(let id):
            let name = terminals.first(where: { $0.id == id })?.name ?? String(localized: "Terminal")
            terminals.removeAll { $0.id == id }
            if selectedTerminalID == id { selectedTerminalID = terminals.first?.id }
            forgetBrowsing(for: id)
            append(note: String(localized: "\(name) closed"))
        case .failed(let id, let message):
            Analytics.terminalFailed(stage: id == nil ? .start : .stream)
            if let id, let index = terminals.firstIndex(where: { $0.id == id }) {
                terminals[index].failure = message
            }
            if let id { clearPendingBrowsing(for: id) }
            // And a run whose shell never arrived is dropped here rather than kept. It is the one
            // thing in this file that outlives the request that set it, and a command left waiting
            // would be fired into whatever shell was opened next — a file the user asked to run
            // once, running at some later moment they did not choose, in a tab they opened for
            // something else.
            pendingRun = nil
            append(note: String(localized: "Terminal: \(message)"))
        }
    
        publishWork()
}
}
