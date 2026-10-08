import Foundation
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
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let total = Int64(try handle.seekToEnd())
                guard total <= FileDownloadLimits.maximumBytes else {
                    sink(.transferFailure(sessionID: id, path: path, message: "That file is larger than this app moves (\(FileDownloadLimits.maximumBytes / 1_048_576) MB)."))
                    return
                }
                try handle.seek(toOffset: UInt64(min(offset, total)))
                let data = try handle.read(upToCount: FileDownloadLimits.chunkBytes) ?? Data()
                sink(.fileRange(sessionID: id, path: path, offset: offset, totalBytes: total, data: data))
                if Self.isArchive(url), offset + Int64(data.count) >= total {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            } catch {
                sink(.transferFailure(sessionID: id, path: path, message: Self.changeMessage(for: error)))
            }
        }
    }

    func archiveFolder(id: UUID, path: String, sink: @escaping Sink) {
        guard path.hasPrefix("/") else {
            sink(.transferFailure(sessionID: id, path: path, message: "That is not a path this Mac can open."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.zip(folder: URL(fileURLWithPath: path).standardizedFileURL) {
            case .success(let archive):
                let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
                guard size <= FileDownloadLimits.maximumBytes else {
                    try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
                    sink(.transferFailure(sessionID: id, path: path, message: "That folder zips to more than this app moves (\(FileDownloadLimits.maximumBytes / 1_048_576) MB)."))
                    return
                }
                sink(.archiveReady(sessionID: id, folder: path, archivePath: archive.path, totalBytes: size))
            case .failure(let message):
                sink(.transferFailure(sessionID: id, path: path, message: message))
            }
        }
    }

    static func isArchive(_ url: URL) -> Bool {
        url.path.hasPrefix(archiveRoot.standardizedFileURL.path + "/")
    }

    private enum ZipOutcome {
        case success(URL)
        case failure(String)
    }

    private static func zip(folder: URL) -> ZipOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("There is no folder at \(folder.path) on this Mac.")
        }
        removeStaleArchives()
        let directory = archiveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = directory.appendingPathComponent("\(folder.lastPathComponent.isEmpty ? "Folder" : folder.lastPathComponent).zip")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure("This Mac could not make room for the zip.")
        }
        // `ditto` rather than `zip`: it keeps what Finder keeps (resource forks, links) and prints nothing on success.
        let made = AgentCommand.output(
            binary: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", folder.path, archive.path],
            directory: URL(fileURLWithPath: "/"),
            environment: [:],
            timeout: 600
        )
        guard made != nil else {
            try? FileManager.default.removeItem(at: directory)
            return .failure("This Mac could not zip that folder.")
        }
        return .success(archive)
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
}
