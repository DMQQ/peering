import Foundation
import PeeringKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    func browsingPath(for id: UUID) -> String? { browsingPaths[id] }

    func setBrowsingPath(_ path: String?, for id: UUID) { browsingPaths[id] = path }

    /// `nil` is wherever the server starts a session: the shell's working directory is not told to this side, and the answer names the folder it resolved to, from which later requests are built.
    func listDirectory(_ path: String?, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return }
        let key = RemoteDirectoryKey(terminalID: id, path: path)
        pendingDirectories.insert(key)
        browseFailures.removeValue(forKey: key)

        Task { @MainActor in
            // "." rather than a guessed home: only the server can answer "wherever you start".
            let outcome: Result<SSHDirectory, any Error>
            do { outcome = .success(try await terminal.session.listDirectory(at: path ?? ".")) }
            catch { outcome = .failure(error) }

            // A shell closed mid-flight takes its answer with it: a listing kept for an unselectable terminal is an entry with no way back, and the key is the shell's identity.
            guard terminals.contains(where: { $0.id == id }) else { return }

            switch outcome {
            case .success(let listing):
                directories[RemoteDirectoryKey(terminalID: id, path: listing.path)] = RemoteDirectory(
                    entries: listing.entries,
                    isTruncated: listing.isTruncated
                )
                pendingDirectories.remove(key)
                browseFailures.removeValue(forKey: key)
                // The one answer that can move a browser: a request that named no folder is answered with the one it resolved to.
                if browsingPaths[id] == nil { browsingPaths[id] = listing.path }
            case .failure(let error):
                pendingDirectories.remove(key)
                browseFailures[key] = Self.browseMessage(error)
            }
        }
    }

    func previewFile(_ path: String, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return }
        // Put up first and filled in when the read lands, as the Mac's browser does: a second state for "asked, not answered" would need keeping in step.
        filePreview = RemoteFilePreview(terminalID: id, path: path)

        Task { @MainActor in
            // The guard before each write: an answer about a file nobody is looking at any more is dropped rather than shown under the wrong name.
            do {
                let contents = try await terminal.session.readFile(at: path)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                filePreview = RemoteFilePreview(
                    terminalID: id,
                    path: contents.path,
                    // The server's own answer about what it read, as the Mac's browser gets; nothing re-derives it from the name.
                    kind: contents.kind,
                    totalBytes: contents.totalBytes,
                    data: contents.data,
                    isComplete: true,
                    // The reader's answer, not this side's guess: they disagree when the file is longer than the cap and the server never said how long it was.
                    reportedTruncation: contents.isTruncated
                )
            } catch {
                Analytics.failed(error, in: .ssh)
                Analytics.sshFailed(error, afterConnected: true)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                // The same dictionary a refused folder goes in: the panel asks for a failure by path, so the preview panel needs nothing added.
                browseFailures[RemoteDirectoryKey(terminalID: id, path: path)] = Self.browseMessage(error)
            }
        }
    }

    func closePreview() {
        filePreview = nil
    }

    /// Refuses a file whose read was cut short: a write replaces the file (SFTP has no partial write), so saving a 128 KB preview of something longer destroys the rest. The panel does not offer to edit such a file; this guard is the last place to stop it.
    func saveFile(_ text: String, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }),
              let preview = filePreview,
              preview.terminalID == id,
              !preview.isTruncated
        else { return }

        let path = preview.path
        isSavingFile = true
        saveFailure = nil

        Task { @MainActor in
            defer { isSavingFile = false }
            do {
                let written = try await terminal.session.writeFile(Data(text.utf8), to: path)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                // Replaced with what the server now holds, not what was sent: they differ only if something went wrong, and the write answers with contents so that has somewhere to show.
                filePreview = RemoteFilePreview(
                    terminalID: id,
                    path: written.path,
                    kind: written.kind,
                    totalBytes: written.totalBytes,
                    data: written.data,
                    isComplete: true,
                    reportedTruncation: written.isTruncated
                )
            } catch {
                Analytics.failed(error, in: .ssh)
                Analytics.sshFailed(error, afterConnected: true)
                guard filePreview?.terminalID == id, filePreview?.path == path else { return }
                saveFailure = Self.browseMessage(error)
            }
        }
    }

    /// The destination is the folder on screen with the file's own name; an existing file is replaced, as a silent rename leaves two files where one is expected.
    /// Capped because of this phone: an enormous upload is an app the system kills, so it is refused with a sentence the user can act on.
    func uploadFile(_ url: URL, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }),
              let folder = browsingPaths[id]
        else { return }

        let name = url.lastPathComponent
        let destination = folder.hasSuffix("/") ? folder + name : folder + "/" + name

        isUploadingFile = true
        uploadFailure = nil

        Task { @MainActor in
            defer { isUploadingFile = false }

            // Security-scoped: a picker file is outside the sandbox and reading it without this fails like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let read: Result<Data, any Error>
            do {
                // The size first, and this order is the fix: it used to be checked after the read, so an over-limit file was read into memory to learn it was too big.
                let size = try await Task.detached {
                    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                }.value
                guard size <= Self.maximumUploadBytes else {
                    throw SSHSessionError.browse(
                        String(localized: "That file is too large to send from this device (the limit is \(Self.maximumUploadBytes / 1_048_576) MB).")
                    )
                }
                // Off the main actor: reading tens of megabytes on it is a hitch on a screen drawing a terminal.
                read = .success(try await Task.detached { try Data(contentsOf: url) }.value)
            } catch {
                read = .failure(error)
            }

            switch read {
            case .failure(let error):
                uploadFailure = Self.browseMessage(error)
            case .success(let data):
                do {
                    _ = try await terminal.session.writeFile(data, to: destination)
                    // The folder on screen is out of date by one file, and asking again is cheaper than patching an entry.
                    listDirectory(folder, sessionID: id)
                } catch {
                    Analytics.failed(error, in: .ssh)
                    Analytics.sshFailed(error, afterConnected: true)
                    uploadFailure = Self.browseMessage(error)
                }
            }
        }
    }

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        change(.create(path: childPath(name, of: folder), kind: kind), sessionID: id)
    }

    /// The path is rebuilt from the folder and the new name, not sent as a destination: a path could name somewhere else.
    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name), name != entry.name else { return }
        change(.rename(path: childPath(entry.name, of: folder), to: name), sessionID: id)
    }

    /// The confirmation is the panel's, where both browsers go through; nothing here can ask, being a `Task` with no view.
    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        change(.delete(path: childPath(entry.name, of: folder)), sessionID: id)
    }

    /// Refused while one is in the air: they share one flag, and the second answer would clear a wait the first owns.
    /// Re-asked on success and failure: nothing here can tell what the filesystem looks like after a half-failed delete.
    private func change(_ operation: RemoteFileOperation, sessionID id: UUID) {
        guard let terminal = terminals.first(where: { $0.id == id }),
              let folder = browsingPaths[id],
              !isChangingFile
        else { return }

        isChangingFile = true
        changeFailure = nil

        Task { @MainActor in
            defer { isChangingFile = false }
            do {
                _ = try await terminal.session.change(operation)
            } catch {
                Analytics.failed(error, in: .ssh)
                Analytics.sshFailed(error, afterConnected: true)
                // The shell has gone, so nobody is left to tell or re-list.
                guard terminals.contains(where: { $0.id == id }) else { return }
                changeFailure = Self.browseMessage(error)
            }
            listDirectory(folder, sessionID: id)
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

    /// For requests never answered: a session that failed or hung up has no loop left to answer, and a waiting panel has no way back.
    func clearPendingBrowsing(for id: UUID) {
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
    }

    func forgetBrowsing(for id: UUID) {
        directories = directories.filter { $0.key.terminalID != id }
        pendingDirectories = pendingDirectories.filter { $0.terminalID != id }
        browseFailures = browseFailures.filter { $0.key.terminalID != id }
        browsingPaths.removeValue(forKey: id)
        if filePreview?.terminalID == id { filePreview = nil }
        // A change in the air through a gone shell cannot finish, and `isChangingFile` disables the panel's controls: left set, the browser returns with a dead New Folder button.
        isChangingFile = false
        changeFailure = nil
    }

    /// The session already words it as the panel shows; this passes it through. What is left is no session: a request made as the connection went.
    private static func browseMessage(_ error: any Error) -> String {
        guard let error = error as? SSHSessionError else { return error.localizedDescription }
        switch error {
        case .browse(let reason): return HostWireText.localized(reason)
        case .notConnected: return String(localized: "The connection ended before the server answered.")
        default: return describe(error)
        }
    }
}
