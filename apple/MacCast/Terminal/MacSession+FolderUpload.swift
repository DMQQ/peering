import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    // MARK: - Sending a folder

    /// **No new protocol, and that is the design rather than a shortcut.** The Mac already answers
    /// "make a folder" and "write this file", so a folder is a walk of this phone's own filesystem
    /// and a sequence of requests the far end has understood since it learned to change a listing.
    /// A recursive message of its own would be a second path to write, a second path to keep in
    /// step with the first, and a feature that does not work at all against a Mac that has not
    /// updated. Nothing on the Mac needs to know a folder is what it is being given.
    func uploadFolder(_ url: URL, toFolder target: String? = nil, sessionID id: UUID) {
        guard let folder = target ?? browsingPaths[id] else { return }

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
                Analytics.failed(error, in: .fileTransfer)
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
    func uploadItems(_ urls: [URL], toFolder target: String? = nil, sessionID id: UUID) {
        guard let folder = target ?? browsingPaths[id], !urls.isEmpty else { return }

        if urls.count == 1 {
            uploadFile(urls[0], toFolder: folder, sessionID: id)
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
        if let line = folderUploads[id]?.line() { return line }
        guard let write = writes[id], write.door == .upload else { return nil }
        let name = write.path.split(separator: "/").last.map(String.init) ?? write.path
        return String(localized: "Sending \u{201C}\(name)\u{201D}…")
    }
}
