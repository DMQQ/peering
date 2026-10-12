import Foundation
import Testing
@testable import RemoteCore

@Suite struct DeadlineTests {
    @Test func aStalledOperationLosesToTheTimer() async {
        await #expect(throws: Deadline.Exceeded.self) {
            try await Deadline.run(
                seconds: 15,
                sleep: { _ in },
                operation: { () async throws -> Int in
                    try await Task.sleep(for: .seconds(3600))
                    return 1
                }
            )
        }
    }

    @Test func aFinishedOperationBeatsTheTimer() async throws {
        let value = try await Deadline.run(
            seconds: 15,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            operation: { 42 }
        )
        #expect(value == 42)
    }

    @Test func anOperationErrorPassesThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await Deadline.run(
                seconds: 15,
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                operation: { () async throws -> Int in throw Boom() }
            )
        }
    }

    @Test func theHandshakeIsStalledOnlyWhileTheMacOwesAnAnswer() {
        #expect(ClientSession.isStalled(.awaitingServerHello))
        #expect(ClientSession.isStalled(.awaitingServerCommit))
        #expect(ClientSession.isStalled(.awaitingServerReveal))
        #expect(!ClientSession.isStalled(.awaitingUserConfirmation))
        #expect(!ClientSession.isStalled(.awaitingPairResult))
        #expect(!ClientSession.isStalled(.ready))
        #expect(!ClientSession.isStalled(.failed))
    }

    @Test func theDeadlinesAreBounded() {
        #expect(ConnectDeadlines.relayRequest == 15)
        #expect(ConnectDeadlines.handshake == 15)
        #expect(ConnectDeadlines.peerDiscovery < ConnectDeadlines.relayRequest)
    }
}
