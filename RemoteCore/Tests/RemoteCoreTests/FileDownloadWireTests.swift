import Foundation
import Testing

@testable import RemoteCore

@Suite struct FileDownloadWireTests {
    private let id = UUID()

    @Test func theRequestsSurviveTheWire() throws {
        for request in [
            TerminalRequest.readRange(sessionID: id, path: "/a/b.txt", offset: 65_536),
            TerminalRequest.archiveFolder(sessionID: id, path: "/a"),
        ] {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(TerminalRequest.self, from: data) == request)
        }
    }

    @Test func theAnswersSurviveTheWire() throws {
        for event in [
            TerminalEvent.fileRange(sessionID: id, path: "/a/b.txt", offset: 0, totalBytes: 10, data: Data([1, 2, 3])),
            TerminalEvent.archiveReady(sessionID: id, folder: "/a", archivePath: "/tmp/x/a.zip", totalBytes: 99),
            TerminalEvent.transferFailure(sessionID: id, path: "/a", message: "No."),
        ] {
            let data = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(TerminalEvent.self, from: data) == event)
        }
    }
}
