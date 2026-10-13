import Testing

@testable import PeeringKit

struct WhatsNewPolicyTests {
    @Test func showsAReleaseTheReturningUserHasNotSeen() {
        #expect(WhatsNewPolicy.decide(currentRelease: "r2", lastSeenRelease: "r1", hasSeenWelcome: true) == .show)
        #expect(WhatsNewPolicy.decide(currentRelease: "r1", lastSeenRelease: nil, hasSeenWelcome: true) == .show)
    }

    @Test func staysQuietOnceTheReleaseIsRecorded() {
        #expect(WhatsNewPolicy.decide(currentRelease: "r1", lastSeenRelease: "r1", hasSeenWelcome: true) == .nothing)
    }

    @Test func recordsWithoutShowingForSomeoneWhoHasNotFinishedTheTour() {
        #expect(WhatsNewPolicy.decide(currentRelease: "r1", lastSeenRelease: nil, hasSeenWelcome: false) == .recordWithoutShowing)
    }

    @Test func doesNothingWhenThereIsNoRelease() {
        #expect(WhatsNewPolicy.decide(currentRelease: nil, lastSeenRelease: nil, hasSeenWelcome: true) == .nothing)
    }
}
