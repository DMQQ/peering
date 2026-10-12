import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    /// Reads as it goes rather than whole: a 2 GB file held in memory gets the app killed.
    func send(contentsOf url: URL, totalBytes: Int, to path: String, sessionID id: UUID) async {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            failTransfer(error, path: path, sessionID: id)
            return
        }
        defer { try? handle.close() }
        await transfer(to: path, totalBytes: totalBytes, sessionID: id) {
            try handle.read(upToCount: Self.writeChunkBytes)
        }
    }

    func send(_ data: Data, to path: String, sessionID id: UUID) async {
        var offset = 0
        await transfer(to: path, totalBytes: data.count, sessionID: id) {
            let end = min(offset + Self.writeChunkBytes, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    /// Each piece waits for room in a window of about 1 MB, so a fast disk and a slow link cannot pile pieces up in memory, and a send error ends the transfer instead of going unseen.
    /// An empty or missing piece ends it early; the empty last piece it sends then is the same message an empty file sends.
    private func transfer(
        to path: String,
        totalBytes: Int,
        sessionID id: UUID,
        nextPiece: () async throws -> Data?
    ) async {
        guard writes[id] != nil, let wire else { return }
        let window = SendWindow()
        uploadWindows[id] = window
        defer { if uploadWindows[id] === window { uploadWindows.removeValue(forKey: id) } }

        var isFinished = false
        do {
            try await wire.sendPaced(.beginWrite(sessionID: id, path: path, totalBytes: totalBytes), weight: 1, through: window)
            var sent = 0
            while !isFinished {
                let piece = sent < totalBytes ? try await nextPiece() ?? Data() : Data()
                sent += piece.count
                let isLast = piece.isEmpty || sent >= totalBytes
                try await wire.sendPaced(
                    .writeChunk(sessionID: id, path: path, data: piece, isLast: isLast),
                    weight: max(piece.count, 1),
                    through: window
                )
                isFinished = isLast
                if !isLast { await Task.yield() }
            }
        } catch {
            abandonTransfer(path: path, sessionID: id)
            failTransfer(error, path: path, sessionID: id)
        }
    }

    /// The wire has no abort request, and adding one would not reach a Mac that has not updated. A last piece that
    /// leaves the file short is already refused by the Mac, which then discards its staging file ("stopped before the
    /// whole file arrived"), so that is the abort. Its refusal is ignored here because the write is no longer recorded.
    private func abandonTransfer(path: String, sessionID id: UUID) {
        wire?.sendTerminal(.writeChunk(sessionID: id, path: path, data: Data(), isLast: true))
    }

    private func failTransfer(_ error: Error, path: String, sessionID id: UUID) {
        let door = writes[id]?.path == path ? writes.removeValue(forKey: id)?.door : nil
        if error is CancellationError { return }
        if let failure = error as? SendWindowFailure, failure.isCancelled { return }

        Analytics.failed(error, in: .fileTransfer)
        let message = error.localizedDescription
        if door == .save {
            saveFailures[id] = message
        } else {
            uploadFailures[id] = message
            stopFolderRun(sessionID: id)
        }
    }

    private func stopFolderRun(sessionID id: UUID) {
        guard folderUploads[id]?.isRunning == true else { return }
        folderUploads[id]?.isRunning = false
    }

    // MARK: - Cancelling

    func isUploading(sessionID id: UUID) -> Bool {
        writes[id]?.door == .upload || folderUploads[id]?.isRunning == true
    }

    /// Stops sending, tells the Mac to drop the half written file, and keeps what a folder run had done so far on screen.
    func cancelUpload(sessionID id: UUID) {
        guard isUploading(sessionID: id) else { return }
        if folderUploads[id]?.isRunning == true {
            stopFolderRun(sessionID: id)
            append(note: String(localized: "Upload cancelled"))
        }
        if writes[id]?.door == .upload { writes.removeValue(forKey: id) }
        uploadWindows[id]?.cancel()
    }
}
