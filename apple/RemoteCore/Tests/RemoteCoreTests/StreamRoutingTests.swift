import Foundation
import Testing
@testable import RemoteCore

struct StreamRoutingTests {
    private let session = UUID()

    private func request(_ value: TerminalRequest) throws -> StreamID? {
        StreamRouting.stream(for: Frame(kind: .terminalRequest, payload: try MessageCodec.encode(value)))
    }

    private func event(_ value: TerminalEvent) throws -> StreamID? {
        StreamRouting.stream(for: Frame(kind: .terminalEvent, payload: try MessageCodec.encode(value)))
    }

    @Test func fileRequestsGoOnTheFilesStream() throws {
        #expect(try request(.listDirectory(sessionID: session, path: nil)) == .files)
        #expect(try request(.readRange(sessionID: session, path: "/a", offset: 0)) == .files)
        #expect(try request(.writeChunk(sessionID: session, path: "/a", data: Data(count: 4000), isLast: false)) == .files)
        #expect(try request(.beginWrite(sessionID: session, path: "/a", totalBytes: 4)) == .files)
        #expect(try request(.archiveFolder(sessionID: session, path: "/a")) == .files)
    }

    @Test func terminalRequestsStayOnTheTerminalStream() throws {
        #expect(try request(.list) == .terminal)
        #expect(try request(.input(sessionID: session, data: Data("ls".utf8))) == .terminal)
        #expect(try request(.resize(sessionID: session, columns: 80, rows: 24)) == .terminal)
        #expect(try request(.close(sessionID: session)) == .terminal)
    }

    @Test func fileEventsGoOnTheFilesStream() throws {
        #expect(try event(.fileRange(sessionID: session, path: "/a", offset: 0, totalBytes: 1, data: Data(count: 3000))) == .files)
        #expect(try event(.directory(sessionID: session, path: "/", entries: [], truncated: false)) == .files)
        #expect(try event(.transferFailure(sessionID: session, path: "/a", message: "no")) == .files)
        #expect(try event(.wroteFile(sessionID: session, path: "/a", totalBytes: 1)) == .files)
    }

    @Test func terminalEventsStayOnTheTerminalStream() throws {
        #expect(try event(.output(sessionID: session, data: Data("x".utf8))) == .terminal)
        #expect(try event(.closed(sessionID: session)) == .terminal)
        #expect(try event(.agents(installed: [])) == .terminal)
    }

    @Test func aPayloadThatIsNotJSONIsTerminalTrafficRatherThanLost() {
        #expect(StreamRouting.stream(for: Frame(kind: .terminalEvent, payload: Data([1, 2, 3]))) == .terminal)
        #expect(StreamRouting.stream(for: Frame(kind: .terminalRequest)) == .terminal)
    }

    @Test func commandsAndInputShareOneStreamSoTheirOrderHolds() {
        let command = Frame(kind: .command, payload: Data("{}".utf8))
        let source = Frame(kind: .setCaptureSource, payload: Data("{}".utf8))
        #expect(StreamRouting.stream(for: command) == .interactive)
        #expect(StreamRouting.stream(for: source) == .interactive)
    }

    @Test func pingAndPongTravelAlone() {
        #expect(StreamRouting.stream(for: Frame(kind: .ping)) == .pulse)
        #expect(StreamRouting.stream(for: Frame(kind: .pong)) == .pulse)
    }

    @Test func theHandshakeTheLaneAndThePictureNeverTravelOnAStream() {
        for kind in [MessageKind.connectionRole, .clientHello, .serverHello, .pairConfirm, .pairResult, .pairCommit, .pairReveal,
                     .error, .videoConfig, .videoFrame, .audioConfig, .audioFrame, .videoChunk, .videoTransport,
                     .videoKeyRequest, .videoKey, .directProbe, .directCommand, .directCandidates, .controlPipe, .stream] {
            #expect(StreamRouting.stream(for: Frame(kind: kind)) == nil, "\(kind)")
        }
    }

    @Test func everyKindIsEitherOnAStreamOrNamedAsNeverOnOne() {
        let never: Set<MessageKind> = [.connectionRole, .clientHello, .serverHello, .pairConfirm, .pairResult, .pairCommit, .pairReveal,
                                       .error, .videoConfig, .videoFrame, .audioConfig, .audioFrame, .videoChunk, .videoTransport,
                                       .videoKeyRequest, .videoKey, .directProbe, .directCommand, .directCandidates, .controlPipe, .stream]
        for kind in MessageKind.allCases where !never.contains(kind) {
            #expect(StreamRouting.stream(for: Frame(kind: kind)) != nil, "\(kind)")
        }
    }
}
