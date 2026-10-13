import PeeringKit
import RemoteCore
import SwiftUI

/// The path is the one that was *asked for*, not the one that came back, so the first request of a
/// browser — the one that names no path and is answered with the home folder of the machine behind
/// the shell — has an entry of its own for as long as it is outstanding.
struct RemoteDirectoryKey: Hashable {
    let terminalID: UUID
    let path: String?
}

struct RemoteDirectory: Equatable {
    var entries: [RemoteDirectoryEntry]
    var isTruncated: Bool
}

struct RemoteFilePreview: Equatable {
    let terminalID: UUID
    let path: String
    var kind = RemoteFileKind.text
    var totalBytes = 0
    var data = Data()
    var isComplete = false

    var text: String { String(decoding: data, as: UTF8.self) }

    /// **The reader's own answer wins when there is one.** The arithmetic below cannot see
    /// everything the reader can: a server that reports no file size leaves `totalBytes` equal to
    /// what arrived, so the comparison says "the whole file" about one that was cut off at the cap.
    /// Only the side that stopped reading knows it stopped, so when it says so that is the answer —
    /// and this is a value somebody's file depends on, because an edit is written back whole.
    /// For a picture it means something blunter than it does for text. A long text file is shown
    /// from the beginning and said to be; a picture that stops at the cap cannot be drawn at all,
    /// because there is no such thing as the first eight megabytes of a JPEG. So the panel refuses
    /// to draw one and says why, rather than handing a decoder half a file and showing whatever
    /// comes out.
    var reportedTruncation: Bool?

    var isTruncated: Bool {
        reportedTruncation ?? (isComplete && data.count < totalBytes)
    }
}
