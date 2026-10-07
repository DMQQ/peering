import Darwin
import Foundation
import RemoteCore
import os

extension TerminalSessionManager {
    enum PreviewOutcome {
        case contents(Data, kind: RemoteFileKind, totalBytes: Int)
        case failure(String)
    }

    func list(id: UUID, requested: String?, sink: @escaping Sink) {
        // Absolute paths only: a relative one resolves against this process's working directory
        // rather than the shell's, which is the directory the user believes they are looking at.
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.browseFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can open."
            ))
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL

        // No notice while it waits: the phone's own "Waiting for your Mac" state explains a slow read, and a failure sent here would be drawn as an error.
        DispatchQueue.global(qos: .userInitiated).async {
            switch DirectoryListing.entries(in: directory) {
            case .entries(let entries, let truncated):
                sink(.directory(
                    sessionID: id,
                    path: directory.path,
                    entries: entries,
                    truncated: truncated
                ))
            case .failure(let message):
                sink(.browseFailure(sessionID: id, path: directory.path, message: message))
            }
        }
    }

    func read(id: UUID, path: String, sink: @escaping Sink) {
        guard path.hasPrefix("/") else {
            sink(.browseFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can open."
            ))
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.contents(of: url) {
            case .contents(let data, let kind, let totalBytes):
                Self.send(data, kind: kind, totalBytes: totalBytes, id: id, path: url.path, sink: sink)
            case .failure(let message):
                sink(.browseFailure(sessionID: id, path: url.path, message: message))
            }
        }
    }

    /// A file's contents, bounded: its text if it is text, and its bytes if it is a picture.
    static func contents(of url: URL) -> PreviewOutcome {
        var info = stat()
        var failure: Int32 = 0
        let looked = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else {
                failure = EINVAL
                return -1
            }
            let result = stat(pointer, &info)
            if result != 0 { failure = errno }
            return result
        }
        guard looked == 0 else { return .failure(DirectoryListing.message(forErrno: failure)) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .failure("That is not a file, so there is nothing to show here.")
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { return .failure(DirectoryListing.message(for: error)) }
        defer { try? handle.close() }

        let totalBytes = Int(info.st_size)
        var data = Data()
        var kind = RemoteFileKind.text
        do {
            // A read may return less than it was asked for, so it is asked again until the cap or
            // the end of the file.
            let probe = min(totalBytes, Self.binaryProbeBytes)
            while data.count < probe {
                guard let piece = try handle.read(upToCount: probe - data.count),
                      !piece.isEmpty else { break }
                data.append(piece)
            }

            guard let sniffed = RemoteFileKind.sniff(prefix: data, path: url.path) else {
                return .failure(
                    "That file is not text or a picture, so there is nothing to show here."
                )
            }
            kind = sniffed

            let limit = min(
                totalBytes,
                kind.isDrawn ? Self.maximumImagePreviewBytes : Self.maximumPreviewBytes
            )
            while data.count < limit {
                guard let piece = try handle.read(upToCount: limit - data.count),
                      !piece.isEmpty else { break }
                data.append(piece)
            }
        } catch {
            return .failure(DirectoryListing.message(for: error))
        }

        if kind == .image { return .contents(data, kind: kind, totalBytes: totalBytes) }

        // It has to decode. Up to three bytes come off the end first, for the case where the read
        // stopped at the cap rather than the end of the file and the cut landed inside a character:
        // calling a text file binary because it was long is the wrong answer.
        var text = data
        var dropped = 0
        while dropped < 3, String(data: text, encoding: .utf8) == nil, !text.isEmpty {
            text = text.dropLast()
            dropped += 1
        }
        guard String(data: text, encoding: .utf8) != nil else {
            return .failure("That file is not text or a picture, so there is nothing to show here.")
        }
        return .contents(text, kind: kind, totalBytes: totalBytes)
    }

    /// What to tell the phone when the filesystem says no.
    static func changeMessage(for error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteFileExistsError:
                return "Something with that name is already there."
            case NSFileNoSuchFileError:
                return "That is no longer there."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return DirectoryListing.message(forErrno: EPERM)
            case NSFileWriteVolumeReadOnlyError:
                return "That disk can only be read from, so nothing can be changed on it."
            case NSFileWriteOutOfSpaceError:
                return FileReplacement.message(for: error)
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ENAMETOOLONG:
                return "That name is too long for this Mac."
            default:
                return DirectoryListing.message(forErrno: Int32(error.code))
            }
        }
        return error.localizedDescription
    }
}
