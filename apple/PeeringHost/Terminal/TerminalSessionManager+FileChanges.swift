import Darwin
import Foundation
import RemoteCore
import os

extension TerminalSessionManager {
    func change(id: UUID, operation: RemoteFileOperation, sink: @escaping Sink) {
        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        guard path.hasPrefix("/") else {
            sink(.fileOperationFailure(
                sessionID: id,
                path: path,
                message: "That is not a path this Mac can change."
            ))
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.perform(operation, at: url) {
            case .done(let note):
                sink(.fileOperationDone(sessionID: id, path: path, note: note))
            case .failure(let message):
                sink(.fileOperationFailure(sessionID: id, path: path, message: message))
            }
        }
    }

    enum ChangeOutcome {
        case done(String)
        case failure(String)
    }

    /// Does the work, and says what to put in the log.
    static func perform(_ operation: RemoteFileOperation, at url: URL) -> ChangeOutcome {
        // Qualified, because `create` and `rename` are also the names of two instance methods that
        // act on a terminal rather than on a file.
        switch operation {
        case .create(_, let kind):
            return Self.create(at: url, kind: kind)
        case .rename(_, let name):
            return Self.rename(at: url, to: name)
        case .delete:
            return Self.delete(at: url)
        }
    }

    /// An empty file, or a folder.
    static func create(at url: URL, kind: RemoteEntryKind) -> ChangeOutcome {
        let name = url.lastPathComponent
        guard RemoteFileName.isValid(name) else {
            return .failure("That is not a name a file can have.")
        }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            return .failure("That folder is no longer there.")
        }

        switch kind {
        case .folder:
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false
                )
            } catch {
                return .failure(changeMessage(for: error))
            }
            return .done("created folder \(name)")

        case .file:
            // `open` with `O_EXCL` rather than `createFile`, for the message rather than the
            // mechanism: `createFile` answers a Bool that is "no" for a name already taken, a
            // folder that is not there, and one this account may not write into, so the code would
            // have to guess which sentence to show, and the obvious guess blames permissions when
            let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                return .failure(changeMessage(for: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )))
            }
            Darwin.close(descriptor)
            return .done("created file \(name)")
        }
    }

    /// A new name for something already in a folder.
    static func rename(at url: URL, to name: String) -> ChangeOutcome {
        // The second of the two checks on a name, and the one that matters, since this end cannot
        // see the keyboard the name was typed on.
        guard RemoteFileName.isValid(name) else {
            return .failure("That is not a name a file can have.")
        }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
        guard renamed.path != url.path else {
            return .done("renamed \(url.lastPathComponent) to \(name)")
        }

        do {
            try FileManager.default.moveItem(at: url, to: renamed)
        } catch {
            return .failure(changeMessage(for: error))
        }
        return .done("renamed \(url.lastPathComponent) to \(name)")
    }

    /// A file, or a folder and everything in it.
    static func delete(at url: URL) -> ChangeOutcome {
        let name = url.lastPathComponent
        // Guard rails against a bug rather than a user: no row in the browser can name the folder
        // you are standing in. A client that has been got at can.
        guard !pathContains(url.path, FileManager.default.homeDirectoryForCurrentUser.path) else {
            return .failure("That is too much of this Mac to delete.")
        }

        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let isFolder = values?.isDirectory == true
        // Counted before the move, because afterwards there is nothing left to walk, and the answer
        // is only ever used for the sentence.
        let contents = isFolder && values?.isSymbolicLink != true
            ? (Self.countInside(url) ?? 1)
            : 1

        do {
            var moved: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
            return .done(contents == 1
                ? "moved \(name) to the Trash"
                : "moved \(name) and \(contents - 1) more to the Trash")
        } catch {
            return .failure(changeMessage(for: error))
        }
    }

    /// How many entries are inside a folder, itself included, or nothing if it cannot be walked.
    static func countInside(_ url: URL) -> Int? {
        guard let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }

        // From one, because the folder itself is going too. A subfolder is counted here and so are
        // its contents, and a link is one thing whatever it points at.
        var count = 1
        while walk.nextObject() != nil { count += 1 }
        return count
    }
}
