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
