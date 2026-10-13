import PeeringKit
import RemoteCore
import SwiftUI

extension MacSession {
    // MARK: - Changing the tree

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        send(operation: .create(path: childPath(name, of: folder), kind: kind), sessionID: id)
    }

    /// The path is rebuilt from the folder and the new name rather than sent as a destination, and
    /// that is the wire's rule rather than this method's convenience: a rename names a thing, while
    /// a path could name somewhere else entirely. See ``RemoteFileOperation/rename(path:to:)``.
    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        guard RemoteFileName.isValid(name) else { return }
        let path = childPath(entry.name, of: folder)
        guard name != entry.name else { return }
        send(operation: .rename(path: path, to: name), sessionID: id)
    }

    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        send(operation: .delete(path: childPath(entry.name, of: folder)), sessionID: id)
    }

    /// Refuses while another is in the air through the same shell. That is not a queue with a
    /// length of one for tidiness: the Mac echoes back the path it was given, so two operations in
    /// flight through one terminal are two answers that could both match one remembered request.
    private func send(operation: RemoteFileOperation, sessionID id: UUID) {
        guard changes[id] == nil else { return }

        let path: String
        switch operation {
        case .create(let target, _), .rename(let target, _), .delete(let target):
            path = target
        }

        changes[id] = FileChange(operation: operation, path: path)
        changeFailures.removeValue(forKey: id)
        wire?.sendTerminal(.changeFile(sessionID: id, operation: operation))
    }

    /// **A rename moves a file, and the browser may be *in* the thing that moved.** Renaming is
    /// asked for from a row, and a row is always a child of the folder on screen, so this side
    /// cannot rename the folder it is looking at — but the browse path is remembered per shell
    /// rather than per view, and a second look after the fact is four lines against a browser that
    /// spends the rest of the session asking about a path that no longer exists.
    /// **A delete takes the folder and everything filed under it.** The pruned cache is not the
    /// only place a listing lives: a folder that was open a moment ago is a listing this end holds
    /// under a path that is a lie now, and stepping back into it would show what used to be there.
    func finish(_ change: FileChange, sessionID id: UUID) {
        let folder = (change.path as NSString).deletingLastPathComponent

        switch change.operation {
        case .create:
            break
        case .rename(_, let name):
            let renamed = childPath(name, of: folder)
            pruneBrowsing(atOrBelow: change.path, sessionID: id)
            if browsingPaths[id] == change.path { browsingPaths[id] = renamed }
        case .delete:
            pruneBrowsing(atOrBelow: change.path, sessionID: id)
        }

        // **Once at the end, not once per entry, when a folder is being sent through this shell.**
        // A folder upload makes a folder per folder, and a listing each would be a directory
        // crossing a channel a keystroke is trying to use, two hundred times over, for a screen the
        // user is not reading until the run finishes. See ``finishFolderUpload(_:sessionID:)``.
        if folderUploads[id]?.isRunning != true {
            listDirectory(folder, sessionID: id)
        }
    }

    func isChangingFile(sessionID id: UUID) -> Bool { changes[id] != nil }

    func changeFailure(sessionID id: UUID) -> String? { changeFailures[id] }
}
