import Testing

@testable import PeeringKit

struct AutoQualityLossTests {
    @Test("heavy datagram loss drops straight to low even when the ping is fine")
    func severeLoss() {
        var policy = AutoQualityPolicy(path: .direct)
        #expect(policy.observe(latencyMilliseconds: 20, newDroppedFrames: 0, datagramLoss: 0.1) == .low)
    }

    @Test("a few percent steps down one tier")
    func noticeableLoss() {
        var policy = AutoQualityPolicy(path: .direct)
        #expect(policy.observe(latencyMilliseconds: 20, newDroppedFrames: 0, datagramLoss: 0.03) == .medium)
    }

    @Test("a lossy but quick link never climbs")
    func lossBlocksClimbing() {
        var policy = AutoQualityPolicy(path: .direct, ceiling: .ultra)
        for _ in 0..<(AutoQualityPolicy.healthySamplesForUpgrade * 2) {
            #expect(policy.observe(latencyMilliseconds: 20, newDroppedFrames: 0, datagramLoss: 0.01) == nil)
        }
    }

    @Test("without loss the climb still happens")
    func cleanClimbs() {
        var policy = AutoQualityPolicy(path: .direct, ceiling: .ultra)
        var result: AutoQualityPolicy.Tier?
        for _ in 0..<AutoQualityPolicy.healthySamplesForUpgrade {
            result = policy.observe(latencyMilliseconds: 20, newDroppedFrames: 0)
        }
        #expect(result == .ultra)
    }
}
