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
            .agents,
            .create,
            .startBrowser(id: id),
            .input(sessionID: id, data: Data([0x1B, 0x5B, 0x41, 0x00])),
            .resize(sessionID: id, columns: 120, rows: 36),
            .rename(sessionID: id, name: "Build"),
            .retitle(sessionID: id, command: "npm run build"),
            .close(sessionID: id),
            .listDirectory(sessionID: id, path: "/Users/someone/Desktop"),
            .listDirectory(sessionID: id, path: nil),
            .readFile(sessionID: id, path: "/Users/someone/Desktop/notes.txt"),
            .beginWrite(sessionID: id, path: "/Users/someone/Desktop/notes.txt", totalBytes: 4_096),
            .beginWrite(sessionID: id, path: "/Users/someone/Desktop/empty.txt", totalBytes: 0),
            .writeChunk(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                // Not text: a chunk boundary may fall inside a character, so nothing may assume UTF-8.
                data: Data([0x00, 0x1B, 0xFF, 0x0A]),
                isLast: false
            ),
            .writeChunk(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                data: Data(),
                isLast: true
            ),
            .changeFile(
                sessionID: id,
                operation: .create(path: "/Users/someone/Desktop/New Folder", kind: .folder)
            ),
            .changeFile(
                sessionID: id,
                operation: .create(path: "/Users/someone/Desktop/New File.txt", kind: .file)
            ),
            .changeFile(
                sessionID: id,
                operation: .rename(
                    path: "/Users/someone/Desktop/notes.txt",
                    to: "meeting notes.txt"
                )
            ),
            .changeFile(
                sessionID: id,
                operation: .delete(path: "/Users/someone/Desktop/New Folder")
            ),
            .registerPushToken(Data([0x9B, 0x00, 0xFF, 0x7A])),
        ]

        for request in requests {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test("host events round-trip with reconnectable snapshot and attention")
    func eventsRoundTrip() throws {
        let id = UUID(uuidString: "8B88D893-55BD-4F68-AF3F-E81D885A50A7")!
        let info = TerminalSessionInfo(id: id, name: "Deploy", isRunning: true, columns: 102, rows: 66)
        let events: [TerminalEvent] = [
            .snapshot([info]),
            .agents(installed: ["claude", "codex"]),
            .created(info),
            .renamed(info),
            .output(sessionID: id, data: Data("ready\r\n".utf8)),
            .attention(sessionID: id, kind: .confirmation, message: "Terminal “Deploy” needs a response."),
            .commandFinished(sessionID: id, command: "npm run build", duration: 65.5, exitStatus: 1),
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
                kind: .text,
                offset: 0,
                totalBytes: 4_096,
                data: Data("first line\n".utf8),
                isLast: false
            ),
            // Bytes that are not text: this payload must never be decoded as a string.
            .fileContents(
                sessionID: id,
                path: "/Users/someone/Desktop/photo.png",
                kind: .image,
                offset: 0,
                totalBytes: 82_000,
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xD8]),
                isLast: false
            ),
            .browseFailure(
                sessionID: id,
                path: "/Users/someone/Desktop",
                message: "Peering is not allowed to read this."
            ),
            .wroteFile(sessionID: id, path: "/Users/someone/Desktop/notes.txt", totalBytes: 4_096),
            // Deliberately distinct from the read failure: one clears the panel, the other leaves the editor open on the user's text.
            .writeFailure(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                message: "That file is too large to send to this Mac."
            ),
            .fileOperationDone(
                sessionID: id,
                path: "/Users/someone/Desktop/New Folder",
                note: "created folder New Folder"
            ),
            .fileOperationDone(
                sessionID: id,
                path: "/Users/someone/Desktop/notes.txt",
                note: "renamed notes.txt to meeting notes.txt"
            ),
            // A change that did not happen is its own event: a folder not read and a folder not changed leave the panel in different states.
            .fileOperationFailure(
                sessionID: id,
                path: "/Users/someone/Desktop/New Folder",
                message: "Something with that name is already there."
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
