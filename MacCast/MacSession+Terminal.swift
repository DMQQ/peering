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

    var canOpenAnotherShell: Bool {
        model.storeManager.access.includes(.shellTabs) || !terminals.contains { $0.isRunning }
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
        // **The concurrency gate, and the reason it is enforced here rather than only on the
        // button.** Three things ask for a shell: the terminal's own `+`, the SSH tab's menu, and a
        // Run from the file browser. A check drawn on one of them would be a check the other two
        // walk past, which is the shape of gate that ends up on a review as a promise the app does
        // not keep.
        guard canOpenAnotherShell else { return }
        pendingTerminalDirectory = path
        wire?.sendTerminal(.create)
    }

    /// **A shell of its own rather than the one the browser is sitting on.** That shell is the one
    /// the user has been typing into, and a file that prints for a minute or waits on a prompt
    /// should not take it over — nor should running one quietly change the directory it was in.
    /// The cost is one round trip between the tap and the output, which is what ``pendingRun`` is.
    /// **On a plan that runs one shell, this types into the one in hand instead.** Running what the
    /// browser lists is part of the browser and is free on every plan, so refusing the run would
    /// break a promise to sell a tab; and opening the tab anyway would be the app granting itself,
    /// silently, exactly what it draws a badge on when the user asks. What is left is the
    /// sentence the feature is described with: a line typed into a shell you already have.
    func runInNewTerminal(_ command: String) {
        guard canOpenAnotherShell else {
            if let target = runningShellTargetID { sendTerminalInput(command, to: target) }
            return
        }
        pendingRun = command
        createTerminal()
    }

    /// `selectedTerminalID` first, which is the shell on screen. A running one as the fallback,
    /// for the case where the selection is one that has ended and the Mac has not said so yet: a
    /// command sent into a dead tab would be a Run that silently did nothing.
    var runningShellTargetID: UUID? {
        terminals.first { $0.id == selectedTerminalID && $0.isRunning }?.id
            ?? terminals.last(where: { $0.isRunning })?.id
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
        wire?.sendTerminal(.input(sessionID: id, data: data))
        wire?.sendTerminal(.retitle(sessionID: id, command: text))
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
        wire?.sendTerminal(.input(sessionID: id, data: Data(bytes)))
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

    // MARK: - Browsing

    static let previewByteLimit = 1024 * 1024

    /// Matching rather than smaller, and that is the point: this side's limit is a backstop against
    /// a Mac that sends more than it promised, and a backstop that engaged below the sender's own
    /// cap would be doing something else entirely. It would cut a picture in half, and half a JPEG
    /// is not a smaller picture, it is no picture at all. So the two numbers agree, and the only
    /// thing the limit here can catch is a Mac that has stopped respecting its own.
    static let imagePreviewByteLimit = 8 * 1024 * 1024

    static func previewByteLimit(for kind: RemoteFileKind) -> Int {
        kind.isDrawn ? imagePreviewByteLimit : previewByteLimit
    }

    func browsingPath(for id: UUID) -> String? { browsingPaths[id] }

    func setBrowsingPath(_ path: String?, for id: UUID) {
        browsingPaths[id] = path
        folderUploads.removeValue(forKey: id)
    }

    func listDirectory(_ path: String?, sessionID id: UUID) {
        let key = RemoteDirectoryKey(terminalID: id, path: path)
        pendingDirectories.insert(key)
        browseFailures.removeValue(forKey: key)
        wire?.sendTerminal(.listDirectory(sessionID: id, path: path))
    }

    func previewFile(_ path: String, sessionID id: UUID) {
        filePreview = RemoteFilePreview(terminalID: id, path: path)
        wire?.sendTerminal(.readFile(sessionID: id, path: path))
    }

    func closePreview() {
        filePreview = nil
    }

    /// It is still a ceiling rather than no ceiling: there is no way to stop a transfer once it has
    /// started, and a mis-tap on a folder of raw footage should not commit somebody to an hour of
    /// it. Declared on both ends, because a limit that only one end enforces is a limit that holds
    /// until the day the other end is older. **The two figures have to move together**: a Mac left
    /// at the old one refuses an upload this end would happily send, and the refusal arrives after
    /// the bytes do.
    static let maximumUploadBytes = 2 * 1_073_741_824

    /// The control channel caps a message at ``ProtocolInfo/maxControlPayload``, and a `Data` in
    /// one is base64 inside JSON, so thirty-two kilobytes of file is some forty-three of payload.
    /// The Mac refuses anything larger rather than trimming it, which makes this a number both
    /// ends have to agree on and one that is written down in both. Duplicated deliberately: a
    /// shared constant would have to travel in the package both ends already import, and the
    /// package is the wrong place for a figure that is really about one function's buffer.
    static let writeChunkBytes = 32 * 1024

    /// **Refuses a file whose read was cut short, and that refusal is the method rather than a
    /// nicety.** A write replaces the file, and there is no "change these bytes", so saving the
    /// first 128 KB of something longer would destroy the rest and leave nothing behind to say it
    /// had happened. The panel does not offer to edit such a file, and this does not extend that
    /// offer any trust: the guard is here because this is the last place it can be.
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

    func uploadFile(_ url: URL, sessionID id: UUID) {
        guard let folder = browsingPaths[id] else { return }
        uploadFile(url, toFolder: folder, sessionID: id)
    }

    func uploadFile(_ url: URL, toFolder folder: String, sessionID id: UUID) {

        if Self.isDirectory(url) {
            uploadFolder(url, sessionID: id)
            return
        }

        let name = url.lastPathComponent
        let destination = folder.hasSuffix("/") ? folder + name : folder + "/" + name
        writes[id] = FileWrite(door: .upload, path: destination)
        uploadFailures.removeValue(forKey: id)

        Task { @MainActor in
            // Security-scoped, because a file from the picker is outside the app's sandbox and
            // reading it without this is a permission failure that looks like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

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
                uploadFailures[id] = String(localized: "That file is too large to send from this device (the limit is \(Self.maximumUploadBytes.formatted(.byteCount(style: .file)))).")
                return
            }
            await send(contentsOf: url, totalBytes: size, to: destination, sessionID: id)
        }
    }

    /// **Awaited between pieces rather than sent in one loop**, and that is about the screen
    /// rather than the wire. Encoding a piece and handing it to the connection happens on the main
    /// actor, so a large upload is thousands of those in a row; yielding between them is not
    /// concurrency, it is the chance for everything else waiting on the main actor, a redraw
    /// above all, to run.
    private func send(_ data: Data, to path: String, sessionID id: UUID) async {
        wire?.sendTerminal(.beginWrite(sessionID: id, path: path, totalBytes: data.count))

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

    // MARK: - Sending a folder

    /// **No new protocol, and that is the design rather than a shortcut.** The Mac already answers
    /// "make a folder" and "write this file", so a folder is a walk of this phone's own filesystem
    /// and a sequence of requests the far end has understood since it learned to change a listing.
    /// A recursive message of its own would be a second path to write, a second path to keep in
    /// step with the first, and a feature that does not work at all against a Mac that has not
    /// updated. Nothing on the Mac needs to know a folder is what it is being given.
    func uploadFolder(_ url: URL, sessionID id: UUID) {
        guard let folder = browsingPaths[id] else { return }

        let name = url.lastPathComponent
        let root = folder.hasSuffix("/") ? folder + name : folder + "/" + name
        uploadFailures.removeValue(forKey: id)

        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let entries: [FolderUploadEntry]
            do {
                entries = try await Self.entries(for: url, in: folder)
            } catch {
                uploadFailures[id] = error.localizedDescription
                return
            }

            guard entries.count > 1 else {
                uploadFailures[id] = String(localized: "That folder is empty.")
                return
            }

            folderUploads[id] = FolderUpload(
                root: root,
                listingFolder: folder,
                entries: entries
            )
            advanceFolderUpload(sessionID: id)
        }
    }

    /// **One run rather than one upload each, and that is what makes a drop work at all.** The
    /// protocol answers through one shell, so this side holds one write in the air per terminal; a
    /// second upload arriving while the first is still going is refused by that guard, and a drop
    /// of five files would have silently delivered one of them.
    /// **A single file keeps the path it always had.** Sending one file into a folder is the
    /// ordinary case, its feedback is the row appearing in the list, and routing it through the run
    /// machinery would put a progress line over the panel for something that is over before it can
    /// be read. Anything else, including a single folder, is a run.
    func uploadItems(_ urls: [URL], sessionID id: UUID) {
        guard let folder = browsingPaths[id], !urls.isEmpty else { return }

        if urls.count == 1 {
            uploadFile(urls[0], sessionID: id)
            return
        }

        uploadFailures.removeValue(forKey: id)

        Task { @MainActor in
            let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (url, held) in zip(urls, scoped) where held {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            var entries: [FolderUploadEntry] = []
            var failure: String?
            for url in urls {
                do {
                    entries += try await Self.entries(for: url, in: folder)
                } catch {
                    // **One thing that could not be read does not cost the rest of the drop.** It
                    // is a folder the walk could not open, or a file whose size could not be read,
                    // and the others are already in hand: sending them and saying what was skipped
                    // is the same bargain every entry in a run makes.
                    failure = error.localizedDescription
                }
            }

            if entries.isEmpty {
                uploadFailures[id] = failure ?? String(localized: "Nothing could be read from what you chose.")
                return
            }

            folderUploads[id] = FolderUpload(root: folder, listingFolder: folder, entries: entries)
            advanceFolderUpload(sessionID: id)
        }
    }

    /// **The folder's own entry first**, because the walk lists what is *inside* a folder and none
    /// of that can be written until the folder exists. Prepended here rather than produced by the
    /// walk, which knows about a directory's contents and has no business knowing what a transfer
    /// intends to do with its name.
    static func entries(for url: URL, in folder: String) async throws -> [FolderUploadEntry] {
        let name = url.lastPathComponent
        let target = folder.hasSuffix("/") ? folder + name : folder + "/" + name

        guard isDirectory(url) else {
            let bytes = try await Task.detached {
                try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }.value
            return [FolderUploadEntry(
                path: target, name: name, isFolder: false, source: url, bytes: bytes
            )]
        }

        let root = FolderUploadEntry(path: target, name: name, isFolder: true, source: nil, bytes: 0)
        let children = try await Task.detached {
            try FolderWalk.entries(of: url, at: target)
        }.value
        return [root] + children
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Entries that need nothing sent are passed over in a loop rather than by recursing, because a
    /// folder can hold thousands of them: a tree of symbolic links or of oversized files would
    /// otherwise be one call per entry.
    func advanceFolderUpload(sessionID id: UUID) {
        guard var upload = folderUploads[id], upload.isRunning else { return }

        while !upload.isFinished {
            let entry = upload.entries[upload.next]
            let needsSending = entry.isFolder
                || (entry.source != nil && entry.bytes <= Self.maximumUploadBytes)
            if needsSending { break }

            upload.entries[upload.next].outcome = entry.source == nil
                ? .skipped(String(localized: "A link to somewhere else, which is not copied."))
                : .failed(String(localized: "Too large to send. The limit is \(Self.maximumUploadBytes.formatted(.byteCount(style: .file)))."))
            upload.next += 1
        }

        if upload.isFinished {
            folderUploads[id] = upload
            finishFolderUpload(upload, sessionID: id)
            return
        }

        guard writes[id] == nil, changes[id] == nil else {
            folderUploads[id] = upload
            return
        }

        let entry = upload.entries[upload.next]
        upload.next += 1
        folderUploads[id] = upload

        if entry.isFolder {
            let operation = RemoteFileOperation.create(path: entry.path, kind: .folder)
            changes[id] = FileChange(operation: operation, path: entry.path)
            wire?.sendTerminal(.changeFile(sessionID: id, operation: operation))
            return
        }

        guard let source = entry.source else { return }
        writes[id] = FileWrite(door: .upload, path: entry.path)
        Task { @MainActor in
            await send(contentsOf: source, totalBytes: entry.bytes, to: entry.path, sessionID: id)
        }
    }

    func finishFolderEntry(path: String, outcome: FolderUploadEntry.Outcome, sessionID id: UUID) {
        guard var upload = folderUploads[id], upload.isRunning else { return }
        // **The entry before the index, not the one at it.** The index moves as the request goes
        // *out* rather than when the answer comes back, so `next - 1` is the entry in flight and
        // `next` is the one after it. Reading the path at `next` would match the wrong entry, and
        // the run would mis-file every outcome and stop at the first one it could not match.
        guard upload.next > 0, upload.entries[upload.next - 1].path == path else { return }

        upload.entries[upload.next - 1].outcome = outcome
        folderUploads[id] = upload
        advanceFolderUpload(sessionID: id)
    }

    /// **Once, not once per file.** Every other upload re-lists the folder so the new file appears,
    /// which for two hundred files would be two hundred listings of the same directory crossing a
    /// channel a keystroke is trying to use. The whole folder is one arrival, so it is one ask.
    /// **The record stays, marked stopped.** What the run came to is the answer to the only question
    /// the user has, and removing it the moment it finishes would leave a folder that looks exactly
    /// as it did before with two files quietly missing from it. It goes when they go somewhere
    /// else. See ``FolderUpload/isRunning``.
    private func finishFolderUpload(_ upload: FolderUpload, sessionID id: UUID) {
        var stopped = upload
        stopped.isRunning = false
        folderUploads[id] = stopped
        listDirectory(upload.listingFolder, sessionID: id)

        let name = upload.root.split(separator: "/").last.map(String.init) ?? upload.root
        append(note: "\(name): \(upload.line())")
    }

    func folderProgress(sessionID id: UUID) -> String? {
        folderUploads[id]?.line()
    }

    /// **Read as it goes rather than whole, and that is the whole of this function.** A
    /// sixty-four megabyte file read in one go is sixty-four megabytes held by an app that is also
    /// decoding a picture and drawing a terminal, and the system kills that app. The user's view of
    /// that failure is the app disappearing for no reason, with nothing to connect it to the upload
    /// they just started.
    /// **The reads are `async`, which is not decoration.** A blocking `FileHandle.read` called from
    /// here would be a disk read on the main actor in the middle of a loop that already yields
    /// between pieces, and the yielding is what this method is measured against: the picture behind
    /// the panel has to keep moving while a file goes out. The async read suspends and lets
    /// everything else on the main actor run, which the yield below then also does explicitly.
    /// **A piece that goes missing does not leave the Mac hanging on a file it was promised.** The
    /// size is known, so the last piece is the one that completes it; a file that shrank under us
    /// between that size being asked for and this running ends the transfer with an empty last
    /// piece rather than with nothing. That is the same message an empty file sends, and the Mac
    /// replaces the file on it: the user gets the bytes that were actually there.
    private func send(contentsOf url: URL, totalBytes: Int, to path: String, sessionID id: UUID) async {
        wire?.sendTerminal(.beginWrite(sessionID: id, path: path, totalBytes: totalBytes))

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
                guard let piece = try handle.read(upToCount: Self.writeChunkBytes), !piece.isEmpty
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

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        send(operation: .create(path: childPath(name, of: folder), kind: kind), sessionID: id)
    }

    /// The path is rebuilt from the folder and the new name rather than sent as a destination, and
    /// that is the wire's rule rather than this method's convenience: a rename names a thing, while
    /// a path could name somewhere else entirely. See ``RemoteFileOperation/rename(path:to:)``.
    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        let path = childPath(entry.name, of: folder)
        guard name != entry.name else { return }
        send(operation: .rename(path: path, to: name), sessionID: id)
    }

    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        send(operation: .delete(path: childPath(entry.name, of: folder)), sessionID: id)
    }

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

    /// **A rename moves a file, and the browser may be *in* the thing that moved.** Renaming is
    /// asked for from a row, and a row is always a child of the folder on screen, so this side
    /// cannot rename the folder it is looking at — but the browse path is remembered per shell
    /// rather than per view, and a second look after the fact is four lines against a browser that
    /// spends the rest of the session asking about a path that no longer exists.
    /// **A delete takes the folder and everything filed under it.** The pruned cache is not the
    /// only place a listing lives: a folder that was open a moment ago is a listing this end holds
    /// under a path that is a lie now, and stepping back into it would show what used to be there.
    private func finish(_ change: FileChange, sessionID id: UUID) {
        let folder = (change.path as NSString).deletingLastPathComponent

        switch change.operation {
        case .create:
            break
        case .rename(_, let name):
            let renamed = childPath(name, of: folder)
            pruneBrowsing(atOrBelow: change.path, sessionID: id)
            if browsingPaths[id] == change.path { browsingPaths[id] = renamed }
        case .delete:
            pruneBrowsing(atOrBelow: change.path, sessionID: id)
        }

        // **Once at the end, not once per entry, when a folder is being sent through this shell.**
        // A folder upload makes a folder per folder, and a listing each would be a directory
        // crossing a channel a keystroke is trying to use, two hundred times over, for a screen the
        // user is not reading until the run finishes. See ``finishFolderUpload(_:sessionID:)``.
        if folderUploads[id]?.isRunning != true {
            listDirectory(folder, sessionID: id)
        }
    }

    func isChangingFile(sessionID id: UUID) -> Bool { changes[id] != nil }

    func changeFailure(sessionID id: UUID) -> String? { changeFailures[id] }

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

    func isWritingFile(sessionID id: UUID) -> Bool { writes[id] != nil }

    func saveFailure(sessionID id: UUID) -> String? { saveFailures[id] }

    func uploadFailure(sessionID id: UUID) -> String? { uploadFailures[id] }

    func clearPendingBrowsing(for id: UUID) {
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
    }

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

    /// How much a shell's output may run past its limit before the tail is rebuilt, so the copy is
    /// paid once per this many bytes rather than once per chunk.
    static let outputSlack = 64 * 1024

    func apply(terminal event: TerminalEvent) {
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
            if !hostPushesTerminalAlertsWhileConnected || model.notifier.remoteToken == nil {
                model.notifier.terminalNeedsAttention(message, sessionID: id, macName: hostName)
            }
        case .commandFinished(let id, let command, let duration, _):
            let named = command.map { "\u{201C}\($0)\u{201D}" }
                ?? terminals.first(where: { $0.id == id }).map { String(localized: "Terminal \u{201C}\($0.name)\u{201D}") }
                ?? String(localized: "Terminal")
            let message = String(localized: "\(named) finished\(TerminalCommandFinishDetector.durationSuffix(duration)).")
            append(note: message)
            if !hostPushesTerminalAlertsWhileConnected || model.notifier.remoteToken == nil {
                model.notifier.terminalFinishedWork(message, sessionID: id, macName: hostName)
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

/// The path is the one that was *asked for*, not the one that came back, so the first request of a
/// browser — the one that names no path and is answered with the home folder of the machine behind
/// the shell — has an entry of its own for as long as it is outstanding.
struct RemoteDirectoryKey: Hashable {
    let terminalID: UUID
    let path: String?
}

struct RemoteDirectory: Equatable {
    var entries: [RemoteDirectoryEntry]
    var isTruncated: Bool
}

struct RemoteFilePreview: Equatable {
    let terminalID: UUID
    let path: String
    var kind = RemoteFileKind.text
    var totalBytes = 0
    var data = Data()
    var isComplete = false

    var text: String { String(decoding: data, as: UTF8.self) }

    /// **The reader's own answer wins when there is one.** The arithmetic below cannot see
    /// everything the reader can: a server that reports no file size leaves `totalBytes` equal to
    /// what arrived, so the comparison says "the whole file" about one that was cut off at the cap.
    /// Only the side that stopped reading knows it stopped, so when it says so that is the answer —
    /// and this is a value somebody's file depends on, because an edit is written back whole.
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
