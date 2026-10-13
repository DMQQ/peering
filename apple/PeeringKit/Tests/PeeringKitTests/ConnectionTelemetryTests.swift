import Testing
import RemoteCore
@testable import MacCastKit

struct ConnectionTelemetryTests {
    private let context = ConnectionTelemetry.Context(
        routes: "lan:timedOut,relay:ok", network: NetworkContext(interface: "wifi", isExpensive: true, isConstrained: false, pathChanges: 5),
        networkChangesDuringSession: 2, hostPlatform: "windows", quotaBucket: "<5m"
    )

    @Test func quotaBucketsCoverEveryRange() {
        #expect(ConnectionBuckets.quotaRemaining(nil) == "unlimited")
        #expect(ConnectionBuckets.quotaRemaining(0) == "0")
        #expect(ConnectionBuckets.quotaRemaining(299) == "<5m")
        #expect(ConnectionBuckets.quotaRemaining(300) == "<15m")
        #expect(ConnectionBuckets.quotaRemaining(900) == ">=15m")
    }

    @Test func byteAndDroppedFrameBucketsCoverEveryRange() {
        #expect(ConnectionBuckets.bytes(0) == "0")
        #expect(ConnectionBuckets.bytes(999_999) == "<1MB")
        #expect(ConnectionBuckets.bytes(50_000_000) == "<100MB")
        #expect(ConnectionBuckets.bytes(5_000_000_000) == ">=1GB")
        #expect(ConnectionBuckets.droppedFrames(0) == "0")
        #expect(ConnectionBuckets.droppedFrames(9) == "<10")
        #expect(ConnectionBuckets.droppedFrames(1000) == ">=1000")
    }

    @Test func routeAttemptsReadInOrderWithTheirOutcomes() {
        var log = RouteAttemptLog()
        log.begin(.lan)
        log.begin(.relay)
        log.finish(.lan, outcome: "timedOut")
        log.finish(.relay, outcome: RouteAttemptLog.succeeded)
        #expect(log.summary == "lan:timedOut,relay:ok")
    }

    @Test func anUnsettledRouteReadsPendingAndASecondReportChangesNothing() {
        var log = RouteAttemptLog()
        log.begin(.lan)
        #expect(log.summary == "lan:pending")
        log.finish(.lan, outcome: "timedOut")
        log.finish(.lan, outcome: "ok")
        #expect(log.summary == "lan:timedOut")
    }

    @Test func routeAttemptsKeepOnlyTheNewest() {
        var log = RouteAttemptLog()
        for _ in 0..<(RouteAttemptLog.capacity + 3) { log.begin(.relay) }
        #expect(log.summary.split(separator: ",").count == RouteAttemptLog.capacity)
    }

    @Test func aFailureCarriesStageDetailTimingAndNetwork() {
        let diagnosis = FailureDiagnosis(
            stage: .streaming, detail: TransportErrorDetail(domain: .posix, code: 54),
            millisecondsToReady: 700, lastFrameAgeMilliseconds: 1200, lastPongAgeMilliseconds: 9000, roundTripMilliseconds: 40
        )
        let properties = ConnectionTelemetry.properties(for: context, diagnosis: diagnosis)
        #expect(properties["stage"] as? String == "streaming")
        #expect(properties["error_domain"] as? String == "posix")
        #expect(properties["error_code"] as? Int == 54)
        #expect(properties["rtt_ms"] as? Int == 40)
        #expect(properties["last_pong_age_ms"] as? Int == 9000)
        #expect(properties["network_interface"] as? String == "wifi")
        #expect(properties["is_expensive"] as? Bool == true)
        #expect(properties["network_path_changes"] as? Int == 2)
        #expect(properties["host_platform"] as? String == "windows")
        #expect(properties["quota_remaining_bucket"] as? String == "<5m")
    }

    @Test func absentFiguresAreLeftOutRatherThanZero() {
        let properties = ConnectionTelemetry.properties(for: context, diagnosis: FailureDiagnosis(stage: .connecting))
        #expect(properties["error_code"] == nil)
        #expect(properties["last_frame_age_ms"] == nil)
        #expect(properties["ms_to_ready"] == nil)
    }

    @Test func anUnknownHostPlatformIsUnknown() {
        #expect(ConnectionTelemetry.hostPlatformName("macos") == "mac")
        #expect(ConnectionTelemetry.hostPlatformName(nil) == "unknown")
        #expect(ConnectionTelemetry.hostPlatformName("plan9") == "unknown")
    }

    @Test func endPropertiesUseTheClosedReasonAndBuckets() {
        let properties = ConnectionTelemetry.endProperties(reason: .retryCapped, durationSeconds: 61, reconnects: 3, videoBytes: 2_000_000, droppedFrames: 12)
        #expect(properties["end_reason"] as? String == "retryCapped")
        #expect(properties["video_bytes_bucket"] as? String == "<10MB")
        #expect(properties["dropped_frames_bucket"] as? String == "<100")
        #expect(properties["duration_s"] as? Int == 61)
    }

    @Test func failureReasonsMapToAnEndReason() {
        #expect(SessionEndReason(failure: .unresponsiveAfterCheck) == .unresponsive)
        #expect(SessionEndReason(failure: .hostClosed) == .hostClosed)
        #expect(SessionEndReason(failure: .timedOut) == .transport)
        #expect(SessionEndReason(failure: .pinMismatch) == .error)
    }

    @Test func networkInterfacePrefersCableThenWifiThenCellular() {
        #expect(NetworkContext.primaryInterface(of: [.cellular, .wifi], isSatisfied: true) == "wifi")
        #expect(NetworkContext.primaryInterface(of: [.wifi, .wired], isSatisfied: true) == "wired")
        #expect(NetworkContext.primaryInterface(of: [.wifi], isSatisfied: false) == "none")
        #expect(NetworkContext(pathChanges: 7).changes(since: 5) == 2)
    }

    @Test func debugAndTestFlightBuildsAreInternal() {
        #expect(BuildChannel.isInternal(isDebug: true, receiptFileName: nil))
        #expect(BuildChannel.isInternal(isDebug: false, receiptFileName: "sandboxReceipt"))
        #expect(!BuildChannel.isInternal(isDebug: false, receiptFileName: "receipt"))
    }
}
