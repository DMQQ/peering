import Testing

@testable import PeeringKit

struct HostSessionFactsTests {
    @Test func anErrorWithNoOwnerIsTaggedWithTheOnlySessionOpen() {
        let facts = HostSessionFacts()
        _ = facts.opened(clientID: "a", sessionRef: "aaaaaaaa", clientPlatform: "ios", viaRelay: false)
        #expect(facts.soleSessionRef == "aaaaaaaa")
    }

    @Test func withTwoSessionsOpenAnErrorWithNoOwnerIsNotTaggedWithEither() {
        let facts = HostSessionFacts()
        _ = facts.opened(clientID: "a", sessionRef: "aaaaaaaa", clientPlatform: "ios", viaRelay: false)
        _ = facts.opened(clientID: "b", sessionRef: "bbbbbbbb", clientPlatform: "android", viaRelay: true)
        #expect(facts.soleSessionRef == nil)
    }

    @Test func theTagComesBackOnceTheOtherSessionHasEnded() {
        let facts = HostSessionFacts()
        _ = facts.opened(clientID: "a", sessionRef: "aaaaaaaa", clientPlatform: "ios", viaRelay: false)
        _ = facts.opened(clientID: "b", sessionRef: "bbbbbbbb", clientPlatform: "ios", viaRelay: false)
        _ = facts.closed(clientID: "a")
        #expect(facts.soleSessionRef == "bbbbbbbb")
    }

    @Test func noSessionMeansNoTag() {
        #expect(HostSessionFacts().soleSessionRef == nil)
    }

    @Test func theFirstEndReasonWins() {
        let facts = HostSessionFacts()
        _ = facts.opened(clientID: "a", sessionRef: nil, clientPlatform: nil, viaRelay: false)
        facts.noteEnd(clientID: "a", .silence)
        facts.noteEnd(clientID: "a", .error)
        #expect(facts.peek(clientID: "a")?.endReason == .silence)
    }

    @Test func everyErrorStageKeepsTheNameTheAnalyticsDocumentsList() {
        let documented: Set<String> = [
            "capture", "stream", "encode", "recovery", "start", "register", "connection", "confirm", "proof", "approval", "save",
            "display", "agent", "fileTransfer", "permission",
        ]
        #expect(Set(HostEventCodes.ErrorStage.allCases.map(\.rawValue)) == documented)
    }
}
