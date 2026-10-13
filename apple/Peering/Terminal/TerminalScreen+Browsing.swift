import PeeringKit
import RemoteCore
import SSHCore
import SwiftUI

extension TerminalScreen {
    // MARK: - Browsing

    /// In place of the terminal, never over it: an overlay would leak taps to the log's keyboard-focus tap and lose the keyboard to terminal output re-asserting first responder. Swapping also keeps the PTY size, since the size reader lives on the log.
    func browsing(_ terminal: RemoteTerminal) -> some View {
        browser(terminal).downloadShareSheet(sessionID: terminal.id)
    }

    private func browser(_ terminal: RemoteTerminal) -> some View {
        VStack(spacing: 0) {
            if let preview = model.filePreview, preview.terminalID == terminal.id {
                FilePreviewPanel(
                    preview: preview,
                    failure: model.browseFailure(preview.path, sessionID: terminal.id),
                    isSaving: model.isWritingFile(sessionID: terminal.id),
                    saveFailure: model.saveFailure(sessionID: terminal.id),
                    onRevealPath: { reveal($0, in: terminal) },
                    onClose: { model.closePreview() },
                    // A shell that has ended cannot be written through: the Mac refuses every request that names it.
                    onSave: terminal.isRunning
                        ? { model.saveFile($0, sessionID: terminal.id) }
                        : nil
                    // Reading and editing stay free; the panel gates the share button itself.
                )
            } else {
                FileBrowserPanel(
                    path: browsingPath,
                    directory: model.directory(browsingPath, sessionID: terminal.id),
                    isLoading: model.isLoadingDirectory(browsingPath, sessionID: terminal.id),
                    // An ended shell is not a failed folder: the Mac refuses every browse request for one.
                    // A failed upload shares the slot, as on the SSH browser.
                    failure: terminal.isRunning
                        ? (model.downloadFailure(sessionID: terminal.id)
                            ?? model.uploadFailure(sessionID: terminal.id)
                            ?? model.browseFailure(browsingPath, sessionID: terminal.id))
                        : String(localized: "This shell has ended. Open a new terminal to browse your Mac's files."),
                    showsHidden: showsHiddenFiles,
                    onToggleHidden: { showsHiddenFiles.toggle() },
                    // The Mac blocks in the listing call while macOS shows a Files-and-Folders prompt and the phone is told nothing, so the wait guesses and says where the answer is.
                    waitingHint: String(localized: "Your Mac is probably asking whether Peering may open this folder. That is a normal macOS question, asked once per folder. Choose Allow on the Mac and the list appears here. Peering only reads folders you open from here."),
                    // Progress of a folder being sent, or what the last one came to.
                    progress: model.downloadProgress(sessionID: terminal.id) ?? model.folderProgress(sessionID: terminal.id),
                    onCancelProgress: model.isUploading(sessionID: terminal.id) ? { model.cancelUpload(sessionID: terminal.id) } : nil,
                    onOpen: { open($0, in: terminal) },
                    onNavigate: { navigate(to: $0, in: terminal) },
                    onRevealPath: { reveal($0, in: terminal) },
                    onReload: {
                        guard terminal.isRunning else { return }
                        model.listDirectory(browsingPath, sessionID: terminal.id)
                    },
                    // Absent while the shell has ended: there is nothing to send a file down.
                    onUpload: terminal.isRunning
                        ? { model.uploadFile($0, sessionID: terminal.id) }
                        : nil,
                    onUploadItems: terminal.isRunning
                        ? { model.uploadItems($0, sessionID: terminal.id) }
                        : nil,
                    onDownload: terminal.isRunning
                        ? { entry in
                            let target = childPath(entry.name, of: browsingPath)
                            if entry.isDirectory {
                                model.downloadFolder(target, sessionID: terminal.id)
                            } else {
                                model.downloadFile(target, sessionID: terminal.id)
                            }
                        }
                        : nil,
                    onUploadInto: terminal.isRunning
                        ? { model.uploadItems($0, toFolder: $1, sessionID: terminal.id) }
                        : nil,
                    // Absent when the shell has ended: a run button types a command into it.
                    onRun: terminal.isRunning ? { run($0, in: terminal) } : nil,
                    // Peering moves things to the Trash on the Mac, where they can be put back; SFTP cannot, so each browser supplies its own wording.
                    deleteHint: String(localized: "It can be put back from the Trash on your Mac."),
                    // Absent until the Mac has said where this browser opens, since a change names a path. `canMake` is the pair.
                    onCreate: canMake(terminal)
                        ? { model.createEntry($0, kind: $1, in: folder, sessionID: terminal.id) }
                        : nil,
                    onRename: canMake(terminal)
                        ? { model.renameEntry($0, to: $1, in: folder, sessionID: terminal.id) }
                        : nil,
                    onDelete: canMake(terminal)
                        ? { model.deleteEntry($0, in: folder, sessionID: terminal.id) }
                        : nil,
                    isChanging: model.isChangingFile(sessionID: terminal.id),
                    changeFailure: model.changeFailure(sessionID: terminal.id),
                    aboveSearch: AnyView(browseControls(terminal))
                )
            }
        }
    }

    func browseControls(_ terminal: RemoteTerminal) -> some View {
        FileBrowseBar(
            isEnabled: terminal.isRunning,
            onInterrupt: { send("\u{03}", to: terminal.id) },
            onEscape: { send("\u{1B}", to: terminal.id) },
            onTab: { send("\t", to: terminal.id) }
        )
    }

    func toggleBrowsing(_ terminal: RemoteTerminal) {
        withAnimation(Motion.tap) { isBrowsing.toggle() }
        if isBrowsing {
            // Asked for on every entry, since a folder can change between looks; not from an ended shell, whose refusal would land on the terminal's tab.
            if terminal.isRunning { model.listDirectory(browsingPath, sessionID: terminal.id) }
        } else {
            model.closePreview()
        }
    }

    var folder: String { browsingPath ?? "" }

    func canMake(_ terminal: RemoteTerminal) -> Bool {
        terminal.isRunning && browsingPath != nil
    }

    func open(_ entry: RemoteDirectoryEntry, in terminal: RemoteTerminal) {
        let path = childPath(entry.name, of: browsingPath)
        if entry.isDirectory {
            navigate(to: path, in: terminal)
        } else {
            model.previewFile(path, sessionID: terminal.id)
        }
    }

    /// A new tab rather than this terminal: a file that prints for a minute or prompts for a password should not take over the shell the user has been typing into.
    func run(_ entry: RemoteDirectoryEntry, in terminal: RemoteTerminal) {
        let path = childPath(entry.name, of: browsingPath)
        model.runInNewTerminal(ShellPath.runCommand(for: path))
        withAnimation(Motion.tap) { isBrowsing = false }
    }

    /// Goes through `sendTerminalBytes` not `sendTerminalInput`: the latter retitles the tab and files the command in history, which a minute of browsing would fill with `cd`.
    func navigate(to path: String, in terminal: RemoteTerminal) {
        model.setBrowsingPath(path, for: terminal.id)
        model.listDirectory(path, sessionID: terminal.id)
        model.sendTerminalBytes(Array("cd -- \(ShellPath.quoted(path))\r".utf8), to: terminal.id)
    }

    /// Back to the terminal as well as into the field, since the field is not on screen while browsing. Quoted, so the field holds the form that runs on Return.
    func reveal(_ path: String, in terminal: RemoteTerminal) {
        withAnimation(Motion.tap) { isBrowsing = false }
        model.closePreview()
        command = ShellPath.quoted(path)
        inputFocused = true
    }

    /// Raw rather than through `sendTerminalInput`, which appends a carriage return and retitles the tab.
    func send(_ text: String, to id: UUID) {
        model.sendTerminalBytes(Array(text.utf8), to: id)
    }

    func submit(to id: UUID) {
        guard !command.isEmpty else { return }
        // Before it is sent: a full-screen program lays out for eighty columns, which a portrait phone only holds at the smallest size. See ``TerminalProgram``.
        if TerminalProgram.prefersSmallText(command) {
            textSize = TerminalMetrics.TextSize.tiny.rawValue
        }
        model.sendTerminalInput(command, to: id)
        command = ""
        inputFocused = true
    }
}
