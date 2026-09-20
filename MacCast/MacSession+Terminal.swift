import MacCastKit
import RemoteCore
import SwiftUI

/// Terminals: the events the Mac sends, and the requests the phone makes.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension MacSession {
    func refreshTerminals() { wire?.sendTerminal(.list) }

    /// Whether one more shell is allowed right now.
    ///
    /// **A fact about the plan and about how many are already running**, which is why it is not
    /// asked of ``StoreManager/access`` at each of the three places a shell can be started. The
    /// free plan runs one shell at a time and ``PlanCapability/shellTabs`` is the second one, so
    /// the question is never "is this paid" on its own: the first shell is free on every plan, and
    /// the badge belongs on the button only once there is one to be concurrent with.
    ///
    /// Asked by the button that draws the badge and by the guard that refuses the request, for the
    /// reason every gate in this app is written once: a gated button over a request that would have
    /// gone through hides a feature from somebody entitled to it, and the other way round is a
    /// badge that opens anyway.
    ///
    /// Counting *running* shells rather than tabs, because a shell that has ended is not something
    /// the relay is carrying and refusing to open the next one over it would strand a user who has
    /// closed everything they had.
    var canOpenAnotherShell: Bool {
        model.storeManager.access.includes(.shellTabs) || !terminals.contains { $0.isRunning }
    }

    /// Opens a shell. It has no name to start with — the Mac numbers it, and the first command
    /// typed into it is what it ends up being called.
    func createTerminal() {
        // **The concurrency gate, and the reason it is enforced here rather than only on the
        // button.** Three things ask for a shell: the terminal's own `+`, the SSH tab's menu, and a
        // Run from the file browser. A check drawn on one of them would be a check the other two
        // walk past, which is the shape of gate that ends up on a review as a promise the app does
        // not keep.
        guard canOpenAnotherShell else { return }
        wire?.sendTerminal(.create)
    }

    /// Opens a shell and runs a command in it.
    ///
    /// **A shell of its own rather than the one the browser is sitting on.** That shell is the one
    /// the user has been typing into, and a file that prints for a minute or waits on a prompt
    /// should not take it over — nor should running one quietly change the directory it was in.
    /// The cost is one round trip between the tap and the output, which is what ``pendingRun`` is.
    ///
    /// **On a plan that runs one shell, this types into the one in hand instead.** Running what the
    /// browser lists is part of the browser and is free on every plan, so refusing the run would
    /// break a promise to sell a tab; and opening the tab anyway would be the app granting itself,
    /// silently, exactly what it draws a badge on when the user asks. What is left is the
    /// sentence the feature is described with: a line typed into a shell you already have.
    func runInNewTerminal(_ command: String) {
        guard canOpenAnotherShell else {
            // `selectedTerminalID` is the shell on screen, which is the one the browser is open
            // over: the browser follows the selected tab, so it cannot be pointing at another.
            // A running shell as the fallback, for the case where the selection is one that has
            // ended and the Mac has not said so yet: a command sent into a dead tab would be a
            // Run that silently did nothing.
            let target = terminals.first { $0.id == selectedTerminalID && $0.isRunning }?.id
                ?? terminals.last(where: { $0.isRunning })?.id
            if let target { sendTerminalInput(command, to: target) }
            return
        }
        pendingRun = command
        createTerminal()
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
        wire?.sendTerminal(.rename(sessionID: id, name: name))
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
        wire?.sendTerminal(.input(sessionID: id, data: data))
        // The command names the terminal it ran in. Whether that name is taken is the Mac's
        // call — a name typed by hand outranks one earned this way.
        wire?.sendTerminal(.retitle(sessionID: id, command: text))
        if let index = terminals.firstIndex(where: { $0.id == id }) {
            terminals[index].attention = nil
            terminals[index].failure = nil
        }
        model.rememberTerminalCommand(text)
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

        model.removeFromTerminalHistory(command)
        lastSentCommand = nil
        lastSentAt = nil
    }

    func sendTerminalBytes(_ bytes: [UInt8], to id: UUID) {
        wire?.sendTerminal(.input(sessionID: id, data: Data(bytes)))
    }

    func resizeTerminal(_ id: UUID, columns: Int, rows: Int) {
        wire?.sendTerminal(.resize(
            sessionID: id,
            columns: UInt16(clamping: columns),
            rows: UInt16(clamping: rows)
        ))
    }

    func closeTerminal(_ id: UUID) {
        wire?.sendTerminal(.close(sessionID: id))
    }

    // MARK: - Browsing

    /// The most of a file this side keeps.
    ///
    /// The Mac caps a preview well below this and the cap here is not the one that binds; it is
    /// here so that the limit on what arrives is a decision this end made rather than one it
    /// inherits — a client that grows to whatever it is sent is one that runs out of memory on a
    /// Mac's mistake.
    static let previewByteLimit = 1024 * 1024

    /// The most of a *picture* this side keeps, which is the same figure the Mac caps one at.
    ///
    /// Matching rather than smaller, and that is the point: this side's limit is a backstop against
    /// a Mac that sends more than it promised, and a backstop that engaged below the sender's own
    /// cap would be doing something else entirely. It would cut a picture in half, and half a JPEG
    /// is not a smaller picture, it is no picture at all. So the two numbers agree, and the only
    /// thing the limit here can catch is a Mac that has stopped respecting its own.
    static let imagePreviewByteLimit = 8 * 1024 * 1024

    /// The most of *this* file to keep, which depends on what it turned out to be.
    static func previewByteLimit(for kind: RemoteFileKind) -> Int {
        kind.isDrawn ? imagePreviewByteLimit : previewByteLimit
    }

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
        wire?.sendTerminal(.listDirectory(sessionID: id, path: path))
    }

    /// Asks the Mac to read a file, replacing whatever was being previewed.
    func previewFile(_ path: String, sessionID id: UUID) {
        filePreview = RemoteFilePreview(terminalID: id, path: path)
        wire?.sendTerminal(.readFile(sessionID: id, path: path))
    }

    func closePreview() {
        filePreview = nil
    }

    /// How large a file this app will send to the Mac.
    ///
    /// Two gigabytes, and **the number is no longer about anybody's memory.** It used to be
    /// sixty-four megabytes on each end for the same shape of reason: this phone read the whole file
    /// in to send it and the Mac collected the pieces in memory to write it, so the figure was the
    /// most either was willing to hold on somebody else's behalf, and past it the honest answer was
    /// no. Both ends stream now, so what is left to bound is the disk the file lands on and the wait
    /// the user is in for.
    ///
    /// It is still a ceiling rather than no ceiling: there is no way to stop a transfer once it has
    /// started, and a mis-tap on a folder of raw footage should not commit somebody to an hour of
    /// it. Declared on both ends, because a limit that only one end enforces is a limit that holds
    /// until the day the other end is older. **The two figures have to move together**: a Mac left
    /// at the old one refuses an upload this end would happily send, and the refusal arrives after
    /// the bytes do.
    static let maximumUploadBytes = 2 * 1_073_741_824

    /// How much of a file travels in one message.
    ///
    /// The control channel caps a message at ``ProtocolInfo/maxControlPayload``, and a `Data` in
    /// one is base64 inside JSON, so thirty-two kilobytes of file is some forty-three of payload.
    /// The Mac refuses anything larger rather than trimming it, which makes this a number both
    /// ends have to agree on and one that is written down in both. Duplicated deliberately: a
    /// shared constant would have to travel in the package both ends already import, and the
    /// package is the wrong place for a figure that is really about one function's buffer.
    static let writeChunkBytes = 32 * 1024

    /// Writes what an editor holds back to the Mac, replacing the file.
    ///
    /// **Refuses a file whose read was cut short, and that refusal is the method rather than a
    /// nicety.** A write replaces the file, and there is no "change these bytes", so saving the
    /// first 128 KB of something longer would destroy the rest and leave nothing behind to say it
    /// had happened. The panel does not offer to edit such a file, and this does not extend that
    /// offer any trust: the guard is here because this is the last place it can be.
    ///
    /// Nothing is shown as saved here. The Mac answers with the size it wrote, and the file is
    /// read back rather than trusted. See the event handling for why.
    func saveFile(_ text: String, sessionID id: UUID) {
        guard let preview = filePreview,
              preview.terminalID == id,
              !preview.isTruncated
        else { return }

        let path = preview.path
        writes[id] = FileWrite(door: .save, path: path)
        saveFailures.removeValue(forKey: id)
        let data = Data(text.utf8)
        Task { @MainActor in await send(data, to: path, sessionID: id) }
    }

    /// Copies a file the user picked into the folder being browsed.
    ///
    /// The destination is the folder on screen and the name is the one the file arrived with,
    /// which is the only naming rule that needs no explanation. An existing file is replaced,
    /// because that is what an upload to a folder you are looking at means, and the alternative,
    /// a silent rename, leaves two files where the user expects one.
    func uploadFile(_ url: URL, sessionID id: UUID) {
        guard let folder = browsingPaths[id] else { return }

        let name = url.lastPathComponent
        let destination = folder.hasSuffix("/") ? folder + name : folder + "/" + name
        writes[id] = FileWrite(door: .upload, path: destination)
        uploadFailures.removeValue(forKey: id)

        Task { @MainActor in
            // Security-scoped, because a file from the picker is outside the app's sandbox and
            // reading it without this is a permission failure that looks like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // **Asked of the filesystem rather than found by reading it.** This is what makes the
            // refusal below cost nothing: a two-gigabyte video is turned away without a byte of it
            // being touched, where reading it first would be the very thing being refused.
            let size: Int
            do {
                size = try await Task.detached {
                    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                }.value
            } catch {
                writes.removeValue(forKey: id)
                uploadFailures[id] = error.localizedDescription
                return
            }
            guard size <= Self.maximumUploadBytes else {
                writes.removeValue(forKey: id)
                uploadFailures[id] = "That file is too large to send from this phone (the limit is \(Self.maximumUploadBytes.formatted(.byteCount(style: .file))))."
                return
            }
            await send(contentsOf: url, totalBytes: size, to: destination, sessionID: id)
        }
    }

    /// Sends a file to the Mac in pieces.
    ///
    /// The pieces go out one after another on a channel that does not reorder them, and nothing is
    /// said about the outcome here: the Mac answers with an event, because it has no other
    /// direction to speak on: the control channel carries both, and a write is acknowledged on
    /// the same sink a shell's output arrives through.
    ///
    /// **Awaited between pieces rather than sent in one loop**, and that is about the screen
    /// rather than the wire. Encoding a piece and handing it to the connection happens on the main
    /// actor, so a large upload is thousands of those in a row; yielding between them is not
    /// concurrency, it is the chance for everything else waiting on the main actor, a redraw
    /// above all, to run.
    private func send(_ data: Data, to path: String, sessionID id: UUID) async {
        wire?.sendTerminal(.beginWrite(sessionID: id, path: path, totalBytes: data.count))

        // An empty file is a transfer with nothing in it, and the last piece still has to be sent:
        // the Mac replaces the file on that message, so a client that stopped after the size would
        // leave it holding a file it had been told about and never given.
        guard !data.isEmpty else {
            wire?.sendTerminal(.writeChunk(sessionID: id, path: path, data: Data(), isLast: true))
            return
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.writeChunkBytes, data.count)
            wire?.sendTerminal(.writeChunk(
                sessionID: id,
                path: path,
                data: data.subdata(in: offset..<end),
                isLast: end == data.count
            ))
            offset = end
            await Task.yield()
        }
    }

    /// Sends a file to the Mac in pieces, reading it a piece at a time as it goes.
    ///
    /// **Read as it goes rather than whole, and that is the whole of this function.** A
    /// sixty-four megabyte file read in one go is sixty-four megabytes held by an app that is also
    /// decoding a picture and drawing a terminal, and the system kills that app. The user's view of
    /// that failure is the app disappearing for no reason, with nothing to connect it to the upload
    /// they just started.
    ///
    /// **The reads are `async`, which is not decoration.** A blocking `FileHandle.read` called from
    /// here would be a disk read on the main actor in the middle of a loop that already yields
    /// between pieces, and the yielding is what this method is measured against: the picture behind
    /// the panel has to keep moving while a file goes out. The async read suspends and lets
    /// everything else on the main actor run, which the yield below then also does explicitly.
    ///
    /// **A piece that goes missing does not leave the Mac hanging on a file it was promised.** The
    /// size is known, so the last piece is the one that completes it; a file that shrank under us
    /// between that size being asked for and this running ends the transfer with an empty last
    /// piece rather than with nothing. That is the same message an empty file sends, and the Mac
    /// replaces the file on it: the user gets the bytes that were actually there.
    ///
    /// Nothing is said about the outcome here. The Mac answers with an event, because the control
    /// channel carries both directions and a write is acknowledged on the same sink a shell's
    /// output arrives through.
    private func send(contentsOf url: URL, totalBytes: Int, to path: String, sessionID id: UUID) async {
        wire?.sendTerminal(.beginWrite(sessionID: id, path: path, totalBytes: totalBytes))

        // An empty file is a transfer with nothing in it, and the last piece still has to be sent:
        // the Mac replaces the file on that message, so a client that stopped after the size would
        // leave it holding a file it had been told about and never given.
        guard totalBytes > 0 else {
            wire?.sendTerminal(.writeChunk(sessionID: id, path: path, data: Data(), isLast: true))
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var sent = 0
            while true {
                // `nil` and an empty `Data` mean the same thing here and are both the end of the
                // file, so one `guard` covers the file shrinking under us and the file simply
                // ending on a piece boundary.
                guard let piece = try await handle.read(upToCount: Self.writeChunkBytes), !piece.isEmpty
                else {
                    if sent < totalBytes {
                        wire?.sendTerminal(.writeChunk(sessionID: id, path: path, data: Data(), isLast: true))
                    }
                    return
                }

                sent += piece.count
                let isLast = sent >= totalBytes
                wire?.sendTerminal(.writeChunk(sessionID: id, path: path, data: piece, isLast: isLast))
                if isLast { return }
                await Task.yield()
            }
        } catch {
            writes.removeValue(forKey: id)
            uploadFailures[id] = error.localizedDescription
        }
    }

    // MARK: - Changing the tree

    /// Makes an empty file or a folder in the folder on screen.
    ///
    /// The name is checked here before anything is sent, which is the first of the two checks —
    /// the Mac makes the second. Not a nicety: a name is typed by a person, and a round trip to be
    /// told that a slash is not a name is a wait for an answer that was already known.
    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        send(operation: .create(path: childPath(name, of: folder), kind: kind), sessionID: id)
    }

    /// Gives something in the folder on screen a new name.
    ///
    /// The path is rebuilt from the folder and the new name rather than sent as a destination, and
    /// that is the wire's rule rather than this method's convenience: a rename names a thing, while
    /// a path could name somewhere else entirely. See ``RemoteFileOperation/rename(path:to:)``.
    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        let path = childPath(entry.name, of: folder)
        guard name != entry.name else { return }
        send(operation: .rename(path: path, to: name), sessionID: id)
    }

    /// Removes something in the folder on screen, and everything inside it if it is a folder.
    ///
    /// The confirmation that makes this safe is the panel's, and it is asked there because that is
    /// the one place both browsers go through — see ``FileBrowserPanel``. Nothing here asks again:
    /// the user has already said yes to a sentence naming what would go.
    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        send(operation: .delete(path: childPath(entry.name, of: folder)), sessionID: id)
    }

    /// One change, and the bookkeeping that makes its answer findable.
    ///
    /// Refuses while another is in the air through the same shell. That is not a queue with a
    /// length of one for tidiness: the Mac echoes back the path it was given, so two operations in
    /// flight through one terminal are two answers that could both match one remembered request.
    private func send(operation: RemoteFileOperation, sessionID id: UUID) {
        guard changes[id] == nil else { return }

        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        changes[id] = FileChange(operation: operation, path: path)
        changeFailures.removeValue(forKey: id)
        wire?.sendTerminal(.changeFile(sessionID: id, operation: operation))
    }

    /// What a change that landed leaves behind.
    ///
    /// Two jobs, and both are about the cache being wrong rather than merely old.
    ///
    /// **A rename moves a file, and the browser may be *in* the thing that moved.** Renaming is
    /// asked for from a row, and a row is always a child of the folder on screen, so this side
    /// cannot rename the folder it is looking at — but the browse path is remembered per shell
    /// rather than per view, and a second look after the fact is four lines against a browser that
    /// spends the rest of the session asking about a path that no longer exists.
    ///
    /// **A delete takes the folder and everything filed under it.** The pruned cache is not the
    /// only place a listing lives: a folder that was open a moment ago is a listing this end holds
    /// under a path that is a lie now, and stepping back into it would show what used to be there.
    private func finish(_ change: FileChange, sessionID id: UUID) {
        let folder = (change.path as NSString).deletingLastPathComponent

        switch change.operation {
        case .create:
            // Nothing was invalidated — a folder's own row does not change when something is put
            // inside it — so the folder is only re-listed, which is the whole of what makes the
            // new row appear.
            break
        case .rename(_, let name):
            let renamed = childPath(name, of: folder)
            pruneBrowsing(atOrBelow: change.path, sessionID: id)
            if browsingPaths[id] == change.path { browsingPaths[id] = renamed }
        case .delete:
            pruneBrowsing(atOrBelow: change.path, sessionID: id)
        }

        listDirectory(folder, sessionID: id)
    }

    /// Whether this terminal is waiting on a change it asked for.
    ///
    /// Read by the panel to disable the controls that would start a second one — see ``changes``.
    func isChangingFile(sessionID id: UUID) -> Bool { changes[id] != nil }

    /// Why the last change through this terminal did not land, if it did not.
    func changeFailure(sessionID id: UUID) -> String? { changeFailures[id] }

    /// Forgets everything cached about a folder and everything under it.
    ///
    /// For the answers that make the cache wrong rather than merely old: a folder that has been
    /// deleted, or one that has been renamed out from under the path it was filed under. Nothing
    /// else clears these, because nothing else can invalidate a listing — a file appearing inside a
    /// folder does not change what that folder's own row says.
    ///
    /// Containment rather than equality, so a folder deleted from a listing takes every listing
    /// below it with it, and the key for the unresolved request — a path of `nil` — is left alone
    /// because it belongs to no folder at all.
    private func pruneBrowsing(atOrBelow path: String, sessionID id: UUID) {
        func isBelow(_ key: RemoteDirectoryKey) -> Bool {
            guard key.terminalID == id, let keyPath = key.path else { return false }
            return pathContains(keyPath, path)
        }
        directories = directories.filter { !isBelow($0.key) }
        pendingDirectories = pendingDirectories.filter { !isBelow($0) }
        browseFailures = browseFailures.filter { !isBelow($0.key) }

        if let preview = filePreview, preview.terminalID == id, pathContains(preview.path, path) {
            filePreview = nil
        }
        if let browsed = browsingPaths[id], pathContains(browsed, path) {
            // The folder on screen was the one that went. Left pointing at it, the browser would
            // keep asking about a path that no longer exists and showing the refusal.
            browsingPaths.removeValue(forKey: id)
        }
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

    /// Whether this terminal is in the middle of writing a file to the Mac.
    ///
    /// Asked by the panel drawing one terminal rather than read off a single flag, for the reason
    /// ``writes`` is keyed by terminal at all.
    func isWritingFile(sessionID id: UUID) -> Bool { writes[id] != nil }

    /// Why the last save through this terminal did not land, if it did not.
    func saveFailure(sessionID id: UUID) -> String? { saveFailures[id] }

    /// Why the last upload through this terminal did not land, if it did not.
    func uploadFailure(sessionID id: UUID) -> String? { uploadFailures[id] }

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
        // A write made through this shell cannot be finished, because every piece after this one is
        // refused by the Mac for naming a terminal that is gone, so the panel stops saying it is
        // waiting for one. The text the editor holds is the panel's own and goes with it.
        writes.removeValue(forKey: id)
        saveFailures.removeValue(forKey: id)
        uploadFailures.removeValue(forKey: id)
        // And a change, for the reason above and one more: the Mac refuses every request naming a
        // terminal that has gone, so this answer is never coming, and the panel's controls are
        // disabled for as long as the entry is here.
        changes.removeValue(forKey: id)
        changeFailures.removeValue(forKey: id)
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
            // The shell a Run button was waiting for. Taken here rather than left set, because the
            // id it needs did not exist until this line — see ``pendingRun``. Through
            // ``sendTerminalInput(_:to:)`` rather than the raw send, so the tab is named after the
            // file it is running and the command lands in the history like any other.
            if let command = pendingRun {
                pendingRun = nil
                sendTerminalInput(command, to: info.id)
            }
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
            model.notifier.terminalNeedsAttention(message, sessionID: id, macName: hostName)
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

        case .fileContents(let id, let path, let kind, let offset, let totalBytes, let data, let isLast):
            guard var preview = filePreview, preview.terminalID == id, preview.path == path else {
                // A piece of a file nobody is looking at any more, or of one opened in another
                // terminal since. Dropped rather than shown under the wrong name.
                return
            }
            // The kind is taken from the wire before the cap is applied, because the cap depends on
            // it. It is the same value on every piece, so which piece arrives first does not matter.
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
                // Read back rather than shown as sent. They are the same bytes unless something went
                // wrong between here and the disk, and asking again is what turns that "unless" into
                // something the user can see: this is the same door the file was read through in
                // the first place, so the panel needs nothing added to it.
                previewFile(path, sessionID: id)
            case .upload:
                // The folder on screen is now out of date by exactly one file, and asking again is
                // cheaper to get right than patching one entry in.
                listDirectory((path as NSString).deletingLastPathComponent, sessionID: id)
            }
            let written = path.split(separator: "/").last.map(String.init) ?? path
            append(note: "Wrote \(written) (\(totalBytes.formatted(.byteCount(style: .file))))")

        case .writeFailure(let id, let path, let message):
            // The panel is left where it was: for a save that is the editor holding the text the
            // user still has, and for an upload it is the folder they are still looking at. Neither
            // is cleared the way a folder that would not open clears the browser.
            guard let write = writes[id], write.path == path else { break }
            writes.removeValue(forKey: id)
            switch write.door {
            case .save: saveFailures[id] = message
            case .upload: uploadFailures[id] = message
            }
            append(note: "Terminal: \(message)")

        case .fileOperationDone(let id, let path, let note):
            // Matched on the path as well as the terminal, exactly as ``wroteFile`` is and for the
            // same reason: a change asked for in one folder that lands after the user has walked
            // into another must not clear a wait belonging to something they have not done.
            guard let change = changes[id], change.path == path else { break }
            changes.removeValue(forKey: id)
            changeFailures.removeValue(forKey: id)
            finish(change, sessionID: id)
            append(note: "Terminal: \(note)")

        case .fileOperationFailure(let id, let path, let message):
            guard let change = changes[id], change.path == path else { break }
            changes.removeValue(forKey: id)
            // Beside the list rather than in place of it. The panel draws `browseFailures` as a
            // full state — a folder that cannot be read has nothing to show — and this is the
            // opposite case: the folder is fine, one thing in it did not happen, and the user is
            // most likely going to try again on the row that is still on screen.
            changeFailures[id] = message
            // A rename that did not land may still have been the one that emptied a folder, and a
            // delete that did not land certainly was not. Re-asking is cheap and is the only way to
            // know which: nothing here can tell what the disk looks like now.
            if case .delete = change.operation {
                listDirectory((path as NSString).deletingLastPathComponent, sessionID: id)
            }

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
            // And a run whose shell never arrived is dropped here rather than kept. It is the one
            // thing in this file that outlives the request that set it, and a command left waiting
            // would be fired into whatever shell was opened next — a file the user asked to run
            // once, running at some later moment they did not choose, in a tab they opened for
            // something else.
            pendingRun = nil
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
    /// What the bytes are, as the Mac decided when it read them.
    ///
    /// Not worked out here from the name, because the two answers are not the same question: a
    /// `.png` that holds text is a text file, and an SVG is text on the wire and a picture on the
    /// screen. The side that looked at the bytes is the side that can say.
    var kind = RemoteFileKind.text
    var totalBytes = 0
    /// The pieces received so far, still joined rather than decoded: a chunk boundary can fall
    /// inside a character, so the text is only read out once the whole of it is here.
    var data = Data()
    var isComplete = false

    /// The bytes as text. Only meaningful when ``kind`` is not a raster image — decoding a
    /// photograph this way is a screenful of replacement characters, which is the whole reason the
    /// kind travels with it.
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
    ///
    /// For a picture it means something blunter than it does for text. A long text file is shown
    /// from the beginning and said to be; a picture that stops at the cap cannot be drawn at all,
    /// because there is no such thing as the first eight megabytes of a JPEG. So the panel refuses
    /// to draw one and says why, rather than handing a decoder half a file and showing whatever
    /// comes out.
    var reportedTruncation: Bool?

    var isTruncated: Bool {
        reportedTruncation ?? (isComplete && data.count < totalBytes)
    }
}
