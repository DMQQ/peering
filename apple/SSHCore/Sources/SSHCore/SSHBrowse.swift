import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

public struct SSHDirectory: Sendable, Equatable {
    /// Absolute and in the server's own spelling: the request may not have named a folder, and every later path is built from this one.
    public let path: String
    public let entries: [RemoteDirectoryEntry]
    public let isTruncated: Bool

    public init(path: String, entries: [RemoteDirectoryEntry], isTruncated: Bool) {
        self.path = path
        self.entries = entries
        self.isTruncated = isTruncated
    }
}

/// `data` is what to show and `totalBytes` is what is on disk; the bytes are already trimmed to a whole number of characters.
public struct SSHFileContents: Sendable, Equatable {
    public let path: String
    public let data: Data
    /// Decided by the server's bytes rather than the name. Defaulted because a write already knows the kind and the answer it gets back is about size.
    public let kind: RemoteFileKind
    public let totalBytes: Int
    /// Whether these bytes are the whole file. Saving a truncated read would replace the file with its first 128 KB, so this travels on the value for the editor and the writer to share.
    public let isTruncated: Bool

    public init(
        path: String,
        data: Data,
        kind: RemoteFileKind = .text,
        totalBytes: Int,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.data = data
        self.kind = kind
        self.totalBytes = totalBytes
        self.isTruncated = isTruncated
    }
}

/// Carried through the same stream as keystrokes because the connection object never leaves the task that opened it (see ``SSHSession``).
struct SSHBrowseRequest: Sendable {
    enum Kind: Sendable {
        case list
        case preview
        /// The whole file, not a patch: SFTP truncates and writes from zero, so handing over less than the file held destroys the difference (hence ``SSHFileContents/isTruncated``). `Data` because an upload is whatever the user picked.
        case write(contents: Data)
        case change(RemoteFileOperation)
    }

    let kind: Kind
    let path: String
    /// A continuation rather than an event on the session's stream, which is `.bufferingNewest(1024)` and would drop the oldest answer under pressure and leave the browser spinning.
    let reply: SSHBrowseReply
}

enum SSHBrowseResult: Sendable {
    case listing(SSHDirectory)
    case contents(SSHFileContents)
    /// What is on the server now, read back after a write so a truncation by a quota or re-encoding does not look saved.
    case written(SSHFileContents)
    /// Composed on the server side because it is the only side that knows how much a recursive delete removed; the caller re-lists the folder.
    case changed(note: String)
}
