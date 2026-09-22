import Foundation
import Testing

@testable import MacCastKit

@Suite("Reading a round trip")
struct LatencyQualityTests {
    @Test("the bands are where the colour said they were")
    func bands() {
        #expect(LatencyQuality.of(milliseconds: 8) == .good)
        #expect(LatencyQuality.of(milliseconds: 39) == .good)
        #expect(LatencyQuality.of(milliseconds: 40) == .fair)
        #expect(LatencyQuality.of(milliseconds: 119) == .fair)
        #expect(LatencyQuality.of(milliseconds: 120) == .poor)
        #expect(LatencyQuality.of(milliseconds: 812) == .poor)
    }

    @Test("a connection that is behaving says nothing at all")
    func goodIsSilent() {
        // **The emptiness is the feature.** The pill is the one line in the app a user reads
        // without asking, so a session that is fine has nothing to report: a line that always
        // carries something is a line nobody can tell apart from a warning.
        #expect(LatencyQuality.good.pillLabel == nil)

        // And when there is something wrong, it is a word a person can act on rather than a
        // figure they have to interpret.
        #expect(LatencyQuality.fair.pillLabel == "Slow")
        #expect(LatencyQuality.poor.pillLabel == "Very slow")
    }

    @Test("every band can be read out to somebody who cannot see the pill")
    func spokenLabels() {
        for quality in LatencyQuality.allCases {
            #expect(!quality.spokenLabel.isEmpty)
        }
        #expect(LatencyQuality.good.spokenLabel != LatencyQuality.poor.spokenLabel)
    }
}
