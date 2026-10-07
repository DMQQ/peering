import MacCastKit
import RemoteCore
import SwiftUI

/// A file, or a folder zipped by the Mac, on its way to a temporary file on this phone.
struct FileDownload {
    let name: String
    /// What the user chose, which is where the answer's path is matched against.
    let sourcePath: String
    let isFolder: Bool
    /// The file being read: the source itself, or the zip once the Mac has made it.
    var readPath: String?
    var window = FileDownloadWindow()
    let destination: URL
    var handle: FileHandle?
}

extension MacSession {
    // MARK: - Downloading

    func downloadFile(_ path: String, sessionID id: UUID) {
        begin(FileDownload(name: Self.fileName(of: path), sourcePath: path, isFolder: false, readPath: path, destination: Self.destination(named: Self.fileName(of: path))), sessionID: id)
    }

    func downloadFolder(_ path: String, sessionID id: UUID) {
        let name = Self.fileName(of: path)
        begin(FileDownload(name: "\(name).zip", sourcePath: path, isFolder: true, readPath: nil, destination: Self.destination(named: "\(name).zip")), sessionID: id)
    }

    func cancelDownload(sessionID id: UUID) {
        guard let download = downloads.removeValue(forKey: id) else { return }
        try? download.handle?.close()
        try? FileManager.default.removeItem(at: download.destination.deletingLastPathComponent())
    }

    func downloadProgress(sessionID id: UUID) -> String? {
        guard let download = downloads[id] else { return nil }
        guard download.readPath != nil else {
            return String(localized: "The Mac is zipping \u{201C}\(Self.fileName(of: download.sourcePath))\u{201D}…")
        }
        guard let fraction = download.window.fraction else {
            return String(localized: "Downloading \u{201C}\(download.name)\u{201D}…")
        }
        return String(localized: "Downloading \u{201C}\(download.name)\u{201D}, \(Int(fraction * 100))%")
    }

    func downloadFailure(sessionID id: UUID) -> String? { downloadFailures[id] }

    func finishedDownload(sessionID id: UUID) -> URL? { finishedDownloads[id] }

    /// Forgets the finished file without deleting it: the share sheet may still be copying it when it closes. Old downloads are swept when the next one starts.
    func clearFinishedDownload(sessionID id: UUID) {
        finishedDownloads.removeValue(forKey: id)
    }

    // MARK: - The Mac's answers

    func apply(fileRange id: UUID, path: String, offset: Int64, totalBytes: Int64, data: Data) {
        guard var download = downloads[id], download.readPath == path else { return }
        do {
            if download.handle == nil {
                try FileManager.default.createDirectory(at: download.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: download.destination.path, contents: nil)
                download.handle = try FileHandle(forWritingTo: download.destination)
            }
            try download.handle?.seek(toOffset: UInt64(offset))
            try download.handle?.write(contentsOf: data)
        } catch {
            Analytics.failed(error, in: .fileTransfer)
            fail(download, message: String(localized: "This phone could not save the file: \(error.localizedDescription)"), sessionID: id)
            return
        }
        let more = download.window.received(count: data.count, totalBytes: totalBytes)
        if download.window.isComplete || (data.isEmpty && more.isEmpty) {
            try? download.handle?.close()
            downloads.removeValue(forKey: id)
            if download.window.isComplete {
                downloadFailures.removeValue(forKey: id)
                finishedDownloads[id] = download.destination
            } else {
                fail(download, message: String(localized: "The Mac sent less of the file than it said it had."), sessionID: id)
            }
            return
        }
        downloads[id] = download
        for next in more {
            wire?.sendTerminal(.readRange(sessionID: id, path: path, offset: next))
        }
    }

    func apply(archiveReady id: UUID, folder: String, archivePath: String) {
        guard var download = downloads[id], download.isFolder, download.sourcePath == folder else { return }
        download.readPath = archivePath
        let first = download.window.first()
        downloads[id] = download
        wire?.sendTerminal(.readRange(sessionID: id, path: archivePath, offset: first))
    }

    func apply(transferFailure id: UUID, path: String, message: String) {
        guard let download = downloads[id], download.readPath == path || download.sourcePath == path else { return }
        fail(download, message: message, sessionID: id)
    }

    // MARK: - Helpers

    private func begin(_ download: FileDownload, sessionID id: UUID) {
        cancelDownload(sessionID: id)
        clearFinishedDownload(sessionID: id)
        downloadFailures.removeValue(forKey: id)
        Self.removeOldDownloads()
        var started = download
        downloads[id] = started
        if started.isFolder {
            wire?.sendTerminal(.archiveFolder(sessionID: id, path: started.sourcePath))
        } else {
            let first = started.window.first()
            downloads[id] = started
            wire?.sendTerminal(.readRange(sessionID: id, path: started.sourcePath, offset: first))
        }
    }

    private func fail(_ download: FileDownload, message: String, sessionID id: UUID) {
        try? download.handle?.close()
        try? FileManager.default.removeItem(at: download.destination.deletingLastPathComponent())
        downloads.removeValue(forKey: id)
        downloadFailures[id] = message
    }

    private static func removeOldDownloads() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PeeringDownloads", isDirectory: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func fileName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "Download" : name
    }

    /// Its own folder per download, so two files of the same name never collide and the whole folder can be deleted after sharing.
    private static func destination(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PeeringDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }
}
