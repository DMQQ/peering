import Darwin
import Foundation
import PeeringKit
import RemoteCore
import os

extension TerminalSessionManager {
    /// A file about to be written, and the three ways that is refused before any of it travels.
    func beginWrite(
        id: UUID,
        path: String,
        totalBytes: Int,
        ownerClientID: String,
        sink: @escaping Sink
    ) {
        guard path.hasPrefix("/") else {
            sink(.writeFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can write to."
            ))
            return
        }
        guard totalBytes >= 0, totalBytes <= Self.maximumWriteBytes else {
            sink(.writeFailure(
                sessionID: id,
                path: path,
                message: "That file is too large to send to this Mac (the limit is \(Self.maximumWriteBytes.formatted(.byteCount(style: .file))))."
            ))
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let key = WriteKey(sessionID: id, path: url.path)
        let target = url.resolvingSymlinksInPath()
        // Derived from the destination behind a leading dot, so it is hidden and sorts beside the
        // file it becomes, and carries a UUID so a second transfer of the same path (which replaces
        // this record) appends to a different file rather than into this one.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).peering-\(UUID().uuidString).part")
        let (replaced, refusedBusy) = lock.withLock { () -> (PendingWrite?, Bool) in
            if writes[key] == nil, writes.count >= UploadWritePolicy.maximumConcurrentTransfers { return (nil, true) }
            let previous = writes.updateValue(
                PendingWrite(
                    ownerClientID: ownerClientID,
                    path: url.path,
                    expected: totalBytes,
                    target: target,
                    staging: staging
                ),
                forKey: key
            )
            return (previous, false)
        }
        guard !refusedBusy else {
            sink(.writeFailure(sessionID: id, path: path, message: FileWork.busyMessage))
            return
        }
        // The record it replaces held a handle and a scratch file that nothing else will ever close.
        if let replaced { Self.writeIO.async { replaced.discard() } }
        rememberStagingFolder(target.deletingLastPathComponent())
        startIdleSweepIfNeeded()
    }

    func write(
        id: UUID,
        path: String,
        data: Data,
        isLast: Bool,
        ownerClientID: String,
        sink: @escaping Sink
    ) {
        let key = WriteKey(sessionID: id, path: URL(fileURLWithPath: path).standardizedFileURL.path)
        guard data.count <= Self.writeChunkBytes else {
            let abandoned = lock.withLock { writes.removeValue(forKey: key) }
            if let abandoned { Self.writeIO.async { abandoned.discard() } }
            sink(.writeFailure(
                sessionID: id,
                path: path,
                message: "That transfer was sent in pieces this Mac cannot accept."
            ))
            return
        }

        /// Three answers rather than two, because most pieces are neither the start nor the end of
        /// anything: a chunk that is not the last is accepted with silence, which a two-case result
        /// would have to spell as a refusal with nothing in it.
        enum State {
            case more(PendingWrite, Data)
            case ready(PendingWrite, Data)
            case refused(String, PendingWrite?)
        }
        let state: State = lock.withLock {
            guard let pending = writes[key] else {
                return .refused("That file is no longer being written. Choose it again.", nil)
            }
            // The declared size is the only thing that says when a file is whole, so a transfer
            // that has stopped agreeing with it has no correct end.
            guard pending.received + data.count <= pending.expected else {
                writes.removeValue(forKey: key)
                return .refused("That transfer sent more than it said it would.", pending)
            }
            // Bytes accepted faster than the disk takes them would sit in memory until the process is killed.
            guard queuedWriteBytes.reserve(data.count) else {
                writes.removeValue(forKey: key)
                return .refused("This Mac's disk is not keeping up, so that transfer was stopped.", pending)
            }
            pending.received += data.count
            pending.lastActivity = ProcessInfo.processInfo.systemUptime
            guard isLast else { return .more(pending, data) }
            guard pending.received == pending.expected else {
                writes.removeValue(forKey: key)
                queuedWriteBytes.release(data.count)
                return .refused("That transfer stopped before the whole file arrived.", pending)
            }
            writes.removeValue(forKey: key)
            return .ready(pending, data)
        }

        switch state {
        case .more(let pending, let piece):
            // The accounting happens here; the bytes go to disk on their own queue. The pieces are
            // enqueued in the order they arrived on one serial queue, so the file they build is the
            // same whether the handle is opened by the first piece or the twentieth.
            Self.writeIO.async {
                Self.append(piece, to: pending)
                self.lock.withLock { self.queuedWriteBytes.release(piece.count) }
            }

        case .refused(let message, let abandoned):
            // Whatever was already appended is thrown away and the destination was never touched. A
            // refusal can arrive after several thousand pieces have gone to disk, which is why the
            // scratch file exists rather than the destination being written.
            if let abandoned { Self.writeIO.async { abandoned.discard() } }
            sink(.writeFailure(sessionID: id, path: path, message: message))

        case .ready(let pending, let piece):
            // The last piece's append and the move that follows it are enqueued together, and the
            // queue is serial, so the move cannot overtake the bytes it is moving.
            Self.writeIO.async {
                Self.append(piece, to: pending)
                self.lock.withLock { self.queuedWriteBytes.release(piece.count) }
                Self.finish(pending) { outcome in
                    // Answered with the path as it arrived, not the standardised one written to:
                    // same file, not always the same string, and the client is holding the one it
                    // sent. An answer it cannot match leaves an editor spinning.
                    switch outcome {
                    case .written(let totalBytes):
                        sink(.wroteFile(sessionID: id, path: path, totalBytes: totalBytes))
                    case .failure(let message):
                        sink(.writeFailure(sessionID: id, path: path, message: message))
                    }
                }
            }
        }
    }

    /// Appends one piece to a transfer's scratch file, opening the file on the first piece.
    static func append(_ piece: Data, to pending: PendingWrite) {
        guard pending.failure == nil else { return }

        if pending.handle == nil {
            do {
                // An empty write rather than `createFile`, because this form answers with why it
                // could not: somebody else's folder, a full volume and a deleted directory all look
                // the same from a `Bool`.
                try Data().write(to: pending.staging)
                pending.handle = try FileHandle(forWritingTo: pending.staging)
            } catch {
                Analytics.failed(error, in: .fileTransfer)
                pending.failure = FileReplacement.message(for: error)
                try? FileManager.default.removeItem(at: pending.staging)
                return
            }
        }

        do {
            try pending.handle?.write(contentsOf: piece)
        } catch {
            Analytics.failed(error, in: .fileTransfer)
            pending.failure = FileReplacement.message(for: error)
        }
    }

    /// Closes a transfer's scratch file and moves it over the destination in one step.
    static func finish(_ pending: PendingWrite, then report: (FileReplacement.Outcome) -> Void) {
        if let failure = pending.failure {
            pending.discard()
            report(.failure(failure))
            return
        }
        try? pending.handle?.close()
        pending.handle = nil
        // The move itself lives in ``FileReplacement``, with tests, because it is a rule that is
        // wrong silently: a replacement that has quietly become a copy across volumes works until
        // the moment it does not.
        report(FileReplacement.commit(staging: pending.staging, to: pending.target))
    }

    /// A preview, in pieces.
    static func send(
        _ data: Data,
        kind: RemoteFileKind,
        totalBytes: Int,
        id: UUID,
        path: String,
        sink: Sink
    ) {
        guard !data.isEmpty else {
            sink(.fileContents(
                sessionID: id,
                path: path,
                kind: kind,
                offset: 0,
                totalBytes: totalBytes,
                data: Data(),
                isLast: true
            ))
            return
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.previewChunkBytes, data.count)
            sink(.fileContents(
                sessionID: id,
                path: path,
                kind: kind,
                offset: offset,
                totalBytes: totalBytes,
                data: data.subdata(in: offset..<end),
                isLast: end == data.count
            ))
            offset = end
        }
    }
}
