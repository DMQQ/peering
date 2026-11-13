import Testing

@testable import RemoteCore

@Suite("Direct path verdict")
struct DirectPathVerdictTests {
    typealias Path = ClientSession.DirectPath

    @Test("knocking with no answer becomes a failure that names the address")
    func probingGivesUp() {
        #expect(Path.probing(peer: "1.2.3.4:5").verdict() == .gaveUp(.noAnswer(peer: "1.2.3.4:5")))
    }

    @Test("never being told where the Mac is becomes a failure of its own kind")
    func noAddressGivesUp() {
        #expect(Path.noAddress.verdict() == .gaveUp(.relayHasNoAddress))
    }

    @Test("a path that opened is not taken back by the deadline")
    func openStays() {
        #expect(Path.open(peer: "1.2.3.4:5").verdict() == .open(peer: "1.2.3.4:5"))
    }

    @Test("only an outcome is recorded: opened, gave up or unusable")
    func resolved() {
        #expect(Path.open(peer: "a").isResolved)
        #expect(Path.gaveUp(.noAnswer(peer: "a")).isResolved)
        #expect(Path.addressUnusable(peer: "a").isResolved)
        #expect(!Path.probing(peer: "a").isResolved)
        #expect(!Path.noAddress.isResolved)
    }

    @Test("an analytics name carries no address")
    func outcomeNamesHaveNoAddress() {
        #expect(!Path.gaveUp(.noAnswer(peer: "1.2.3.4:5")).outcomeName.contains("1.2"))
    }
}
