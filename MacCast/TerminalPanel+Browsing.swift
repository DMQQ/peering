import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI

extension TerminalPanel {
    // MARK: - Browsing

    /// The browser, or the file it is showing, in the terminal's place.
    ///
    /// **In place of, never over.** Two things in this panel make an overlay impossible rather
    /// than merely untidy: the log carries a tap that sends focus to the keyboard, so anything
    /// laid on top of it leaks every stray tap to the terminal; and terminal output re-asserts
    /// first responder on the field whenever it is focused, so during a `tail -f` an overlay's own
    /// controls would lose the keyboard dozens of times a second. Swapping them also leaves the
    /// PTY size alone: the `GeometryReader` that reports it lives on the log, so with the log out
    /// of the hierarchy nothing is measured and ``applySize``'s change guard makes the return trip
    /// a no-op — no reflow, and no `vim` redrawn at a size it never had.
    func browsing(_ terminal: RemoteTerminal) -> some View {
        VStack(spacing: 0) {
            if let preview = model.filePreview, preview.terminalID == terminal.id {
                FilePreviewPanel(
                    preview: preview,
                    failure: model.browseFailure(preview.path, sessionID: terminal.id),
                    isSaving: model.isWritingFile(sessionID: terminal.id),
                    saveFailure: model.saveFailure(sessionID: terminal.id),
                    onRevealPath: { reveal($0, in: terminal) },
                    onClose: { model.closePreview() },
                    // A shell that has ended cannot be written through, for the reason it cannot
                    // be listed through: the Mac refuses every request that names it. Absent
                    // rather than failing on the tap, so the pencil is not offered over a file
                    // that the next save would only be refused.
                    onSave: terminal.isRunning
                        ? { model.saveFile($0, sessionID: terminal.id) }
                        : nil
                    // Reading and editing a file stay free; handing it to the phone does not, and
                    // the panel gates the share button itself. See
                    // ``PlanCapability/fileTransfer`` for where the line is drawn and why it is
                    // drawn there rather than around the whole browser.
                )
            } else {
                FileBrowserPanel(
                    path: browsingPath,
                    directory: model.directory(browsingPath, sessionID: terminal.id),
                    isLoading: model.isLoadingDirectory(browsingPath, sessionID: terminal.id),
                    // A shell that has ended is not a folder that failed. The Mac refuses every
                    // browse request for one — a stopped shell has no directory to change into —
                    // and the panel says that itself rather than asking and spinning at a Mac that
                    // has already answered.
                    //
                    // An upload that failed shares the slot, as it does on the SSH browser and for
                    // the reason recorded there: it is a fact about this folder, the next attempt
                    // clears it, and a second place for a sentence to appear in a panel this short
                    // would be a second layout to keep right.
                    failure: terminal.isRunning
                        ? (model.uploadFailure(sessionID: terminal.id)
                            ?? model.browseFailure(browsingPath, sessionID: terminal.id))
                        : "This shell has ended. Open a new terminal to browse your Mac's files.",
                    showsHidden: showsHiddenFiles,
                    // The Mac blocks inside the listing call while macOS puts a Files-and-Folders
                    // question on its screen, and nothing about that reaches this phone: the
                    // request is simply outstanding. So the wait says what it is probably waiting
                    // for, and where the answer is. It is a guess with a delay on it — see the
                    // panel — and it is the only thing the user can act on from here.
                    waitingHint: "If your Mac is asking whether Peering may read this folder, answer it there.",
                    // What a folder being sent is doing, or what the last one came to. One line,
                    // and the only thing on this screen that says a run of hundreds of operations
                    // is happening at all. See ``FileBrowserPanel/progress``.
                    progress: model.folderProgress(sessionID: terminal.id),
                    onOpen: { open($0, in: terminal) },
                    onNavigate: { navigate(to: $0, in: terminal) },
                    onRevealPath: { reveal($0, in: terminal) },
                    onReload: {
                        guard terminal.isRunning else { return }
                        model.listDirectory(browsingPath, sessionID: terminal.id)
                    },
                    // Absent while the shell has ended, for the same reason the folder cannot be
                    // listed then: there is nothing left to send a file down, and an upload button
                    // that opens a picker and then fails is worse than no button.
                    onUpload: terminal.isRunning
                        ? { model.uploadFile($0, sessionID: terminal.id) }
                        : nil,
                    // Everything the picker or a drop can hand over, folders and all, as one run.
                    // See ``MacSession/uploadItems(_:sessionID:)``.
                    onUploadItems: terminal.isRunning
                        ? { model.uploadItems($0, sessionID: terminal.id) }
                        : nil,
                    // The other direction is the same capability and the panel's own gate, so a
                    // plan that moves files both ways or a plan that does not move them at all
                    // needs no value passed down. The `nil` above stays a fact about this session
                    // rather than about the account: a shell that has ended draws no upload button
                    // at all, where a plan without file transfer draws one that cannot be pressed.
                    // And absent for the same reason: a run button types a command into a shell, so
                    // a shell that has ended is one with nothing to type into.
                    onRun: terminal.isRunning ? { run($0, in: terminal) } : nil,
                    // The Mac's own answer to "what happens to it", and the reason the two browsers
                    // hand this in rather than sharing one: Peering moves things to the Trash on
                    // the Mac, where they can be put back, and there is no such thing on an SFTP
                    // server. Two machines, two weights on one word.
                    deleteHint: "It can be put back from the Trash on your Mac.",
                    // The three changes, absent together and for a reason of their own on top of
                    // the shell being live: a change names a path, and until the Mac has said where
                    // this browser opens there is no path to name. `canMake` is the pair.
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
                    changeFailure: model.changeFailure(sessionID: terminal.id)
                )
            }
            browseControls(terminal)
        }
    }

    /// The row under the browser, which is ``FileBrowseBar`` — the same row the SSH terminal draws
    /// under its browser, because it is the same set of controls acting on the same kind of list.
    /// What differs between the two is only what each closure asks and of which machine.
    func browseControls(_ terminal: RemoteTerminal) -> some View {
        FileBrowseBar(
            isEnabled: terminal.isRunning,
            showsHidden: showsHiddenFiles,
            onInterrupt: { send("\u{03}", to: terminal.id) },
            onEscape: { send("\u{1B}", to: terminal.id) },
            onTab: { send("\t", to: terminal.id) },
            onReload: { model.listDirectory(browsingPath, sessionID: terminal.id) },
            onToggleHidden: { showsHiddenFiles.toggle() }
        )
    }

    /// The switch between the terminal and the Mac's files, as one action rather than two.
    ///
    /// It sends nothing to the shell. Browsing is a way of looking at the Mac's folders and, when
    /// a folder is opened, of asking the shell to change directory — there is no state here the
    /// shell is told about. What it does either way is draw the difference: the button that calls
    /// this is in the header on both screens — see ``TerminalModeButton``.
    func toggleBrowsing(_ terminal: RemoteTerminal) {
        withAnimation(Motion.tap) { isBrowsing.toggle() }
        if isBrowsing {
            // Asked for on every entry rather than only the first: a folder is the one screen
            // where what is on it can have changed since it was last looked at. Not asked for
            // at all from a shell that has ended, which would be refused and would leave the
            // refusal on the terminal's tab — a mark about browsing, on a terminal.
            if terminal.isRunning { model.listDirectory(browsingPath, sessionID: terminal.id) }
        } else {
            model.closePreview()
        }
    }

    /// Where something would be made, renamed or deleted. Only meaningful when ``canMake``.
    ///
    /// The empty string is unreachable rather than a fallback: ``canMake(_:)`` is false whenever
    /// there is no browsing path, and every closure that reads this is `nil` at the same time.
    var folder: String { browsingPath ?? "" }

    /// Whether this browser can change anything on the Mac.
    ///
    /// Both halves are needed. The shell has to be running, because every change is a request
    /// through it; and the folder has to have resolved, because a change names a path and the path
    /// is the one thing this panel does not have until the Mac has said where the browser opens.
    func canMake(_ terminal: RemoteTerminal) -> Bool {
        terminal.isRunning && browsingPath != nil
    }

    /// A row was tapped: folders are entered, files are read.
    func open(_ entry: RemoteDirectoryEntry, in terminal: RemoteTerminal) {
        let path = childPath(entry.name, of: browsingPath)
        if entry.isDirectory {
            navigate(to: path, in: terminal)
        } else {
            model.previewFile(path, sessionID: terminal.id)
        }
    }

    /// Runs an executable file, in a shell of its own.
    ///
    /// The confirmation has already happened — the panel holds it, so that neither browser can be
    /// the one that forgot it. What is left is the command and where it goes.
    ///
    /// A **new tab** rather than this terminal, and the difference is worth naming: the shell
    /// behind this browser is one the user has been typing into, and a file that prints for a
    /// minute, prompts for a password or runs until it is interrupted should not take that over.
    /// Leaving the browser as well, because the whole reason someone pressed Run is to see what
    /// came out of it, and the output goes to the terminal that just opened.
    func run(_ entry: RemoteDirectoryEntry, in terminal: RemoteTerminal) {
        let path = childPath(entry.name, of: browsingPath)
        model.runInNewTerminal(ShellPath.runCommand(for: path))
        withAnimation(Motion.tap) { isBrowsing = false }
    }

    /// Goes into a folder: the browser shows it, and the shell changes directory to it.
    ///
    /// The `cd` goes through ``SessionModel/sendTerminalBytes(_:to:)`` rather than
    /// ``SessionModel/sendTerminalInput(_:to:)``, and that is the whole difference between browsing
    /// and typing. The other one retitles the tab to the command it just sent and files that
    /// command in the history, so a minute of looking through folders would leave the user's
    /// history full of `cd` and their terminal called `cd -- '/Users/…'`.
    func navigate(to path: String, in terminal: RemoteTerminal) {
        model.setBrowsingPath(path, for: terminal.id)
        model.listDirectory(path, sessionID: terminal.id)
        model.sendTerminalBytes(Array("cd -- \(ShellPath.quoted(path))\r".utf8), to: terminal.id)
    }

    /// Puts a path on the command line, which is what a path is usually wanted for.
    ///
    /// Back to the terminal as well as into the field: the field is not on screen while the
    /// browser is, and a path put somewhere nobody can see it is a tap that did nothing. Quoted,
    /// because a path is data and the shell is a shell — what goes in the field is the form that
    /// runs when Return is pressed. The keyboard comes up with it, exactly as the history strip
    /// does when a command is tapped there.
    func reveal(_ path: String, in terminal: RemoteTerminal) {
        withAnimation(Motion.tap) { isBrowsing = false }
        model.closePreview()
        command = ShellPath.quoted(path)
        inputFocused = true
    }

    /// One key's bytes, to one shell. Raw rather than through `sendTerminalInput`, which appends
    /// a carriage return and retitles the tab: a control character is not a command, and a tab
    /// called "⌃C" would be a tab named after a keystroke.
    func send(_ text: String, to id: UUID) {
        model.sendTerminalBytes(Array(text.utf8), to: id)
    }

    func submit(to id: UUID) {
        guard !command.isEmpty else { return }
        // **Before it is sent, and for the reason the terminal is small at all.** A full-screen
        // program lays itself out for eighty columns, and on a phone held upright the only size
        // that holds eighty is the smallest one: run this and the first thing the user sees is the
        // two-thirds of it that fits. See ``TerminalProgram``.
        if TerminalProgram.prefersSmallText(command) {
            textSize = TerminalMetrics.TextSize.tiny.rawValue
        }
        model.sendTerminalInput(command, to: id)
        command = ""
        inputFocused = true
    }
}
