import PeeringKit
import RemoteCore
import SwiftUI

extension MacSession {
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
#if DEBUG
        if AgentSeed.wantsFakeMac { return answerSeededListing(path, sessionID: id) }
#endif
        let key = RemoteDirectoryKey(terminalID: id, path: path)
        pendingDirectories.insert(key)
        browseFailures.removeValue(forKey: key)
        wire?.sendTerminal(.listDirectory(sessionID: id, path: path))
    }

    func previewFile(_ path: String, sessionID id: UUID) {
#if DEBUG
        if AgentSeed.wantsFakeMac { return answerSeededPreview(path, sessionID: id) }
#endif
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
            uploadFolder(url, toFolder: folder, sessionID: id)
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
                Analytics.failed(error, in: .fileTransfer)
                Analytics.fileTransferFailed(error, direction: .up, stage: .measure, bytes: nil)
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

    /// Containment rather than equality, so a folder deleted from a listing takes every listing
    /// below it with it, and the key for the unresolved request — a path of `nil` — is left alone
    /// because it belongs to no folder at all.
    func pruneBrowsing(atOrBelow path: String, sessionID id: UUID) {
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
        cancelUpload(sessionID: id)
        writes.removeValue(forKey: id)
        saveFailures.removeValue(forKey: id)
        uploadFailures.removeValue(forKey: id)
        // And a change, for the reason above and one more: the Mac refuses every request naming a
        // terminal that has gone, so this answer is never coming, and the panel's controls are
        // disabled for as long as the entry is here.
        changes.removeValue(forKey: id)
        changeFailures.removeValue(forKey: id)
        cancelDownload(sessionID: id)
        finishedDownloads.removeValue(forKey: id)
        downloadFailures.removeValue(forKey: id)
    }
}
