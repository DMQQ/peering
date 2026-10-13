import Testing

@testable import PeeringKit

@Suite("Tying an activity refusal to its push")
struct ActivityPushLedgerTests {
    private let start = ContinuousClock.now

    @Test("a refusal with an id names exactly that push, not the latest one")
    func idPicksItsOwnPush() {
        var ledger = ActivityPushLedger()
        ledger.record(requestId: "a1", clientID: "phone-1", token: "t1", now: start)
        ledger.record(requestId: "b2", clientID: "phone-2", token: "t2", now: start + .seconds(1))
        #expect(ledger.entry(for: "a1", now: start + .seconds(2)) == .init(clientID: "phone-1", token: "t1"))
    }

    @Test("without an id the most recent push is the guess")
    func noIDFallsBackToLatest() {
        var ledger = ActivityPushLedger()
        ledger.record(requestId: "a1", clientID: "phone-1", token: "t1", now: start)
        ledger.record(requestId: "b2", clientID: "phone-2", token: "t2", now: start + .seconds(1))
        #expect(ledger.entry(for: nil, now: start + .seconds(500)) == .init(clientID: "phone-2", token: "t2"))
    }

    @Test("an id that expired or was never seen names nothing")
    func unknownIDNamesNothing() {
        var ledger = ActivityPushLedger()
        ledger.record(requestId: "a1", clientID: "phone-1", token: "t1", now: start)
        ledger.record(requestId: "b2", clientID: "phone-2", token: "t2", now: start + .seconds(30))
        #expect(ledger.entry(for: "a1", now: start + .seconds(61)) == nil)
        #expect(ledger.entry(for: "b2", now: start + .seconds(61)) != nil)
        #expect(ledger.entry(for: "zz", now: start + .seconds(1)) == nil)
    }

    @Test("a new push drops entries past the retention")
    func recordPrunes() {
        var ledger = ActivityPushLedger()
        ledger.record(requestId: "a1", clientID: "phone-1", token: "t1", now: start)
        ledger.record(requestId: "b2", clientID: "phone-1", token: "t1", now: start + .seconds(120))
        #expect(ledger.entry(for: "a1", now: start + .seconds(121)) == nil)
    }

    @Test("a generated id is short hex")
    func requestIDShape() {
        let id = ActivityPushLedger.makeRequestID()
        #expect(id.count == 8)
        #expect(id.allSatisfy { $0.isHexDigit })
    }
}
