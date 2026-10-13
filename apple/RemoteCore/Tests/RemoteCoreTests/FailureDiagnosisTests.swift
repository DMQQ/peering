import Foundation
import Network
import Testing
@testable import RemoteCore

struct FailureDiagnosisTests {
    @Test func aPosixErrorKeepsItsErrno() {
        let detail = TransportErrorDetail(NWError.posix(.ECONNRESET))
        #expect(detail == TransportErrorDetail(domain: .posix, code: 54))
    }

    @Test func aTLSErrorKeepsItsStatus() {
        let detail = TransportErrorDetail(NWError.tls(-9806))
        #expect(detail == TransportErrorDetail(domain: .tls, code: -9806))
    }

    @Test func anErrorThatIsNotNetworkHasNoDetail() {
        struct Other: Error {}
        #expect(TransportErrorDetail(Other()) == nil)
    }

    @Test func aTLSErrorWhileConnectingIsTheTLSStage() {
        let tls = TransportErrorDetail(domain: .tls, code: -9808)
        #expect(ConnectStage.atFailure(tracked: .connecting, reason: .transport, detail: tls) == .tls)
    }

    @Test func aTLSErrorAfterTheHandshakeKeepsTheStageItHappenedIn() {
        let tls = TransportErrorDetail(domain: .tls, code: -9806)
        #expect(ConnectStage.atFailure(tracked: .streaming, reason: .transport, detail: tls) == .streaming)
    }

    @Test func aLostPictureIsTheVideoStage() {
        #expect(ConnectStage.atFailure(tracked: .streaming, reason: .videoLost, detail: nil) == .video)
    }

    @Test func stagesAreOrderedByHowFarTheSessionGot() {
        #expect(ConnectStage.resolving < .connecting)
        #expect(ConnectStage.pairing < .ready)
        #expect(ConnectStage.streaming < .video)
    }

    @Test func agesAreMeasuredBackFromNowInMilliseconds() {
        let diagnosis = FailureDiagnosis.make(
            trackedStage: .streaming, reason: .unresponsive, detail: nil,
            now: 100, lastPictureAt: 98.5, lastReplyAt: 91, roundTripMilliseconds: 41.6, millisecondsToReady: 820
        )
        #expect(diagnosis.lastFrameAgeMilliseconds == 1500)
        #expect(diagnosis.lastPongAgeMilliseconds == 9000)
        #expect(diagnosis.roundTripMilliseconds == 42)
        #expect(diagnosis.millisecondsToReady == 820)
        #expect(diagnosis.stage == .streaming)
    }

    @Test func aMissingStampIsAMissingAgeNotZero() {
        let diagnosis = FailureDiagnosis.make(
            trackedStage: .ready, reason: .unresponsive, detail: nil,
            now: 10, lastPictureAt: nil, lastReplyAt: nil, roundTripMilliseconds: nil, millisecondsToReady: nil
        )
        #expect(diagnosis.lastFrameAgeMilliseconds == nil)
        #expect(diagnosis.lastPongAgeMilliseconds == nil)
        #expect(diagnosis.roundTripMilliseconds == nil)
    }

    @Test func aStampAheadOfNowIsClampedAtZero() {
        let diagnosis = FailureDiagnosis.make(
            trackedStage: .ready, reason: .other, detail: nil,
            now: 10, lastPictureAt: 10.2, lastReplyAt: nil, roundTripMilliseconds: nil, millisecondsToReady: nil
        )
        #expect(diagnosis.lastFrameAgeMilliseconds == 0)
    }
}
