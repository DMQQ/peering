import Foundation
import MacCastKit
import RemoteCore

extension TerminalSessionManager {
    /// Where zipped folders wait to be read. One folder per archive, so the zip keeps the folder's own name when the phone saves it.
    static let archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PeeringArchives", isDirectory: true)

    private static let archiveLifetime: TimeInterval = 3600

    func readRange(id: UUID, path: String, offset: Int64, sink: @escaping Sink) {
        guard path.hasPrefix("/"), offset >= 0 else {
            sink(.transferFailure(sessionID: id, path: path, message: "That is not a path this Mac can open."))
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        FileWork.run(work: { Self.chunk(of: url, at: offset) }) { outcome in
            switch outcome {
            case .done(.success(let piece)):
                sink(.fileRange(sessionID: id, path: path, offset: offset, totalBytes: piece.total, data: piece.data))
                if Self.isArchive(url), offset + Int64(piece.data.count) >= piece.total {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            case .done(.failure(let message)):
                sink(.transferFailure(sessionID: id, path: path, message: message))
            case .timedOut:
                sink(.transferFailure(sessionID: id, path: path, message: FileWork.timedOutMessage))
            case .busy:
                sink(.transferFailure(sessionID: id, path: path, message: FileWork.busyMessage))
            }
        }
    }

    private struct Chunk: Sendable {
        let data: Data
        let total: Int64
    }

    private enum ChunkOutcome: Sendable {
        case success(Chunk)
        case failure(String)
    }

    private static func chunk(of url: URL, at offset: Int64) -> ChunkOutcome {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let total = Int64(try handle.seekToEnd())
            guard total <= FileDownloadLimits.maximumBytes else {
                return .failure("That file is larger than this app moves (\(FileDownloadLimits.maximumBytes / 1_048_576) MB).")
            }
            try handle.seek(toOffset: UInt64(min(offset, total)))
            let data = try handle.read(upToCount: FileDownloadLimits.chunkBytes) ?? Data()
            return .success(Chunk(data: data, total: total))
        } catch {
            return .failure(Self.changeMessage(for: error))
        }
    }

    func archiveFolder(id: UUID, path: String, ownerClientID: String, sink: @escaping Sink) {
        guard path.hasPrefix("/") else {
            sink(.transferFailure(sessionID: id, path: path, message: "That is not a path this Mac can open."))
            return
        }
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        FileWork.run(limiter: FileWork.archiving, timeout: 700, work: { Self.zip(folder: folder) }) { [weak self] outcome in
            switch outcome {
            case .done(.success(let archive)):
                let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
                guard size <= FileDownloadLimits.maximumBytes else {
                    try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
                    sink(.transferFailure(sessionID: id, path: path, message: Self.tooLargeMessage))
                    return
                }
                self?.lock.withLock { self?.archiveDirectories[ownerClientID, default: []].append(archive.deletingLastPathComponent()) }
                sink(.archiveReady(sessionID: id, folder: path, archivePath: archive.path, totalBytes: size))
            case .done(.failure(let message)):
                sink(.transferFailure(sessionID: id, path: path, message: message))
            case .timedOut:
                sink(.transferFailure(sessionID: id, path: path, message: FileWork.timedOutMessage))
            case .busy:
                sink(.transferFailure(sessionID: id, path: path, message: FileWork.busyMessage))
            }
        }
    }

    private static var tooLargeMessage: String {
        "That folder zips to more than this app moves (\(FileDownloadLimits.maximumBytes / 1_048_576) MB)."
    }

    static func isArchive(_ url: URL) -> Bool {
        url.path.hasPrefix(archiveRoot.standardizedFileURL.path + "/")
    }

    private enum ZipOutcome: Sendable {
        case success(URL)
        case failure(String)
    }

    private static func zip(folder: URL) -> ZipOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("There is no folder at \(folder.path) on this Mac.")
        }
        removeStaleArchives()
        guard ArchiveBudget.hasRoom(freeBytes: freeBytesOnArchiveVolume(), cap: FileDownloadLimits.maximumBytes) else {
            return .failure("There is not enough free space on this Mac to zip that folder.")
        }
        let directory = archiveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = directory.appendingPathComponent("\(folder.lastPathComponent.isEmpty ? "Folder" : folder.lastPathComponent).zip")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure("This Mac could not make room for the zip.")
        }
        // `ditto` rather than `zip`: it keeps what Finder keeps (resource forks, links) and prints nothing on success.
        let result = GroupProcess.run(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", folder.path, archive.path],
            directory: URL(fileURLWithPath: "/"),
            environment: [:],
            outputLimit: 64 * 1024,
            timeout: 600,
            shouldAbort: {
                let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
                return ArchiveBudget.mustStop(archiveBytes: size, cap: FileDownloadLimits.maximumBytes)
            }
        )
        guard let result, result.status == 0, !result.timedOut, !result.stopped else {
            try? FileManager.default.removeItem(at: directory)
            return .failure(result?.stopped == true ? tooLargeMessage : "This Mac could not zip that folder.")
        }
        return .success(archive)
    }

    private static func freeBytesOnArchiveVolume() -> Int64 {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func removeStaleArchives() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)) ?? []
        for name in names {
            let url = archiveRoot.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > archiveLifetime {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Nothing from a previous run can still be read: the phone that asked is long gone.
    static func removeAllArchives() {
        try? FileManager.default.removeItem(at: archiveRoot)
    }

    /// A client that leaves takes the zips it asked for with it.
    func removeArchives(for clientID: String) {
        let directories = lock.withLock { archiveDirectories.removeValue(forKey: clientID) ?? [] }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }
}
