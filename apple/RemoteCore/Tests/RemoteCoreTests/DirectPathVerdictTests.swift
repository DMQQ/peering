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

    @Test("the verdict is due at the deadline and not before")
    func verdictDeadline() {
        #expect(!Path.verdictIsDue(after: .seconds(7)))
        #expect(!Path.verdictIsDue(after: .milliseconds(7_999)))
        #expect(Path.verdictIsDue(after: .seconds(8)))
        #expect(Path.verdictIsDue(after: .seconds(60)))
    }

    @Test("a repeated outcome is not news")
    func repeatedOutcomeIsNotNews() {
        #expect(Path.probing(peer: "a").updated(with: .probing(peer: "a")) == nil)
        #expect(Path.noAddress.updated(with: .noAddress) == nil)
    }

    @Test("a look-up saying knocking does not take back a path that is open or given up")
    func knockingDoesNotDowngrade() {
        #expect(Path.open(peer: "a").updated(with: .probing(peer: "b")) == nil)
        #expect(Path.gaveUp(.noAnswer(peer: "a")).updated(with: .probing(peer: "a")) == nil)
    }

    @Test("a path that was given up on can still open, and a new outcome replaces an old one")
    func laterOutcomesReplace() {
        #expect(Path.gaveUp(.noAnswer(peer: "a")).updated(with: .open(peer: "a")) == .open(peer: "a"))
        #expect(Path.notTried.updated(with: .noAddress) == .noAddress)
        #expect(Path.noAddress.updated(with: .probing(peer: "a")) == .probing(peer: "a"))
        #expect(Path.open(peer: "a").updated(with: .open(peer: "b")) == .open(peer: "b"))
    }
}
