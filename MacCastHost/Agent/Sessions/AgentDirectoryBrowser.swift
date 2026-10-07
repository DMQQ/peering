import Foundation
import RemoteCore

/// One folder's contents for the chat's folder picker.
enum AgentDirectoryBrowser {
    static func list(requested: String?, sink: @escaping AgentSessionManager.Sink) {
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.browseFailure(path: path, message: "That is not a folder this Mac can open."))
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        FolderAccessWatch.run(
            slow: { sink(.browseWaiting(path: directory.path, message: FolderAccessWatch.listingMessage)) },
            work: { DirectoryListing.entries(in: directory) }
        ) { outcome in
            switch outcome {
            case .entries(let entries, let truncated):
                sink(.directory(path: directory.path, entries: entries, truncated: truncated))
            case .failure(let message):
                sink(.browseFailure(path: directory.path, message: message))
            }
        }
    }
}
