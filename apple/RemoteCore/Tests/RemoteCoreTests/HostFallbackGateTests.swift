import Foundation
import Testing

@testable import RemoteCore

@Suite("The host's answer to a control-channel fallback request")
struct HostFallbackGateTests {
    @Test("a recent frame is served")
    func recentFrameIsServed() {
        #expect(HostFallbackGate.answer(now: 104, lastProducedAt: 100, holdsRecoveryPoint: false) == .serve)
    }

    @Test("a long still screen with no held keyframe is declined")
    func staleWithoutKeyframeIsDeclined() {
        #expect(HostFallbackGate.answer(now: 120, lastProducedAt: 100, holdsRecoveryPoint: false) == .decline)
    }

    @Test("a long still screen with a held keyframe is served, so the lost first picture can be resent")
    func staleWithKeyframeIsServed() {
        #expect(HostFallbackGate.answer(now: 120, lastProducedAt: 100, holdsRecoveryPoint: true) == .serve)
    }

    @Test("nothing ever produced is declined")
    func neverProducedIsDeclined() {
        #expect(HostFallbackGate.answer(now: 120, lastProducedAt: nil, holdsRecoveryPoint: false) == .decline)
    }
}
