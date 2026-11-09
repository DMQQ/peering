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

    @Test func aRangeAnsweredByAnOlderMacHasNoChecksum() throws {
        let current = try JSONEncoder().encode(TerminalEvent.fileRange(sessionID: id, path: "/a", offset: 0, totalBytes: 1, data: Data([1]), md5: "abc"))
        var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        var body = try #require(object["fileRange"] as? [String: Any])
        body.removeValue(forKey: "md5")
        object["fileRange"] = body
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TerminalEvent.self, from: old)
        #expect(decoded == .fileRange(sessionID: id, path: "/a", offset: 0, totalBytes: 1, data: Data([1]), md5: nil))
    }

    @Test func theAnswersSurviveTheWire() throws {
        for event in [
            TerminalEvent.fileRange(sessionID: id, path: "/a/b.txt", offset: 0, totalBytes: 10, data: Data([1, 2, 3]), md5: "5289df737df57326fcdd22597afb1fac"),
            TerminalEvent.archiveReady(sessionID: id, folder: "/a", archivePath: "/tmp/x/a.zip", totalBytes: 99),
            TerminalEvent.transferFailure(sessionID: id, path: "/a", message: "No."),
        ] {
            let data = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(TerminalEvent.self, from: data) == event)
        }
    }
}
