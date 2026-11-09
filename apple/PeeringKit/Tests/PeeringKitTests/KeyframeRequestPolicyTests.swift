import Testing

@testable import PeeringKit

struct KeyframeRequestPolicyTests {
    @Test func aDropAtTheStartOfAWaitDoesNotAsk() {
        var policy = KeyframeRequestPolicy()
        let at10 = policy.noteDrop(at: 10)
        #expect(!at10)
        let at10_2 = policy.noteDrop(at: 10.2)
        #expect(!at10_2)
    }

    @Test func aWaitPastTheGraceAsksOnce() {
        var policy = KeyframeRequestPolicy()
        let at10 = policy.noteDrop(at: 10)
        #expect(!at10)
        let at10_3 = policy.noteDrop(at: 10.3)
        #expect(at10_3)
        let at10_5 = policy.noteDrop(at: 10.5)
        #expect(!at10_5)
    }

    @Test func aWaitThatOutlastsTheCooldownAsksAgain() {
        var policy = KeyframeRequestPolicy()
        _ = policy.noteDrop(at: 10)
        let at10_4 = policy.noteDrop(at: 10.4)
        #expect(at10_4)
        let at11_3 = policy.noteDrop(at: 11.3)
        #expect(!at11_3)
        let at11_4 = policy.noteDrop(at: 11.4)
        #expect(at11_4)
    }

    @Test func recoveringStartsTheGraceOver() {
        var policy = KeyframeRequestPolicy()
        _ = policy.noteDrop(at: 10)
        policy.noteRecovered()
        let at20 = policy.noteDrop(at: 20)
        #expect(!at20)
        let at20_2 = policy.noteDrop(at: 20.2)
        #expect(!at20_2)
        let at20_3 = policy.noteDrop(at: 20.3)
        #expect(at20_3)
    }
}
