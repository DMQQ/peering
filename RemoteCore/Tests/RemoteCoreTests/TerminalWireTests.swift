import Foundation
import Testing

@testable import RemoteCore

@Suite("Terminal wire protocol")
struct TerminalWireTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test("client requests round-trip without losing binary input")
    func requestsRoundTrip() throws {
        let id = UUID(uuidString: "8B88D893-55BD-4F68-AF3F-E81D885A50A7")!
        let requests: [TerminalRequest] = [
            .list,
            .create,
            .input(sessionID: id, data: Data([0x1B, 0x5B, 0x41, 0x00])),
            .resize(sessionID: id, columns: 120, rows: 36),
            .rename(sessionID: id, name: "Build"),
            .retitle(sessionID: id, command: "npm run build"),
            .close(sessionID: id),
            .listDirectory(sessionID: id, path: "/Users/someone/Desktop"),
            // The one request that names no path, which the host answers with its home folder.
            .listDirectory(sessionID: id, path: nil),
            .readFile(sessionID: id, path: "/Users/someone/Desktop/notes.txt"),
            .beginWrite(sessionID: id, path: "/Users/someone/Desktop/notes.txt", totalBytes: 4_096),
            // An empty file, which is the one transfer that is a request and a last piece with
            // nothing between them.
            .beginWrite(sessionID: id, path: "/Users/someone/Desktop/empty.txt", totalBytes: 0),
            .writeChunk(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                // Bytes that are not text, because a chunk boundary may fall inside a character and
                // the pieces are joined before they are decoded, so nothing here may assume UTF-8.
                data: Data([0x00, 0x1B, 0xFF, 0x0A]),
                isLast: false
            ),
            .writeChunk(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                data: Data(),
                isLast: true
            ),
        ]

        for request in requests {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test("host events round-trip with reconnectable snapshot and attention")
    func eventsRoundTrip() throws {
        let id = UUID(uuidString: "8B88D893-55BD-4F68-AF3F-E81D885A50A7")!
        let info = TerminalSessionInfo(id: id, name: "Deploy", isRunning: true)
        let events: [TerminalEvent] = [
            .snapshot([info]),
            .created(info),
            .renamed(info),
            .output(sessionID: id, data: Data("ready\r\n".utf8)),
            .attention(sessionID: id, kind: .confirmation, message: "Terminal “Deploy” needs a response."),
            .exited(sessionID: id, status: 0),
            .closed(sessionID: id),
            .failed(sessionID: id, message: "Could not start the shell."),
            .directory(
                sessionID: id,
                path: "/Users/someone/Desktop",
                entries: [
                    RemoteDirectoryEntry(
                        name: "notes.txt",
                        isDirectory: false,
                        isSymlink: false,
                        size: 1_244,
                        permissions: "-rw-r--r--",
                        modified: Date(timeIntervalSince1970: 1_760_000_000)
                    ),
                    // A link that points at a folder is both, which is the case the two flags
                    // together exist for.
                    RemoteDirectoryEntry(
                        name: "shortcut",
                        isDirectory: true,
                        isSymlink: true,
                        size: 0,
                        permissions: "lrwxr-xr-x",
                        modified: nil
                    ),
                ],
                truncated: true
            ),
            .fileContents(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                offset: 0,
                totalBytes: 4_096,
                data: Data("first line\n".utf8),
                isLast: false
            ),
            .browseFailure(
                sessionID: id,
                path: "/Users/someone/Desktop",
                message: "Peering is not allowed to read this."
            ),
            .wroteFile(sessionID: id, path: "/Users/someone/Desktop/notes.txt", totalBytes: 4_096),
            // A write that did not land, which is deliberately a different event from the read
            // failure above: one clears the panel and the other leaves the editor open on the text
            // the user still has.
            .writeFailure(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                message: "That file is too large to send to this Mac."
            ),
        ]

        for event in events {
            #expect(try roundTrip(event) == event)
        }
    }

    @Test("terminal frames have distinct stable message kinds")
    func messageKinds() {
        #expect(MessageKind.terminalRequest.rawValue == 0x15)
        #expect(MessageKind.terminalEvent.rawValue == 0x16)
        #expect(MessageKind.allCases.contains(.terminalRequest))
        #expect(MessageKind.allCases.contains(.terminalEvent))
    }

    @Test("terminal text removes ANSI and applies carriage return and backspace")
    func sanitizesTerminalText() {
        let bytes = Data("\u{1B}[32mgreen\u{1B}[0m\rblue\nabc\u{08}d\u{1B}]0;title\u{07}".utf8)
        #expect(TerminalTextSanitizer.render(bytes) == "blue\nabd")
    }
}
