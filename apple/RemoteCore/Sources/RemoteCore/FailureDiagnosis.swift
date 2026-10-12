import Foundation

/// What a failed session knew about itself, taken at the moment it failed before the watches that hold these figures are reset. Numbers and closed sets only: it is read by analytics.
public struct FailureDiagnosis: Sendable, Equatable {
    public let stage: ConnectStage
    public let detail: TransportErrorDetail?
    public let millisecondsToReady: Int?
    /// Since the last picture, `nil` when none ever arrived.
    public let lastFrameAgeMilliseconds: Int?
    /// Since the Mac last answered a ping, `nil` when it never did.
    public let lastPongAgeMilliseconds: Int?
    public let roundTripMilliseconds: Int?

    public init(
        stage: ConnectStage, detail: TransportErrorDetail? = nil, millisecondsToReady: Int? = nil,
        lastFrameAgeMilliseconds: Int? = nil, lastPongAgeMilliseconds: Int? = nil, roundTripMilliseconds: Int? = nil
    ) {
        self.stage = stage
        self.detail = detail
        self.millisecondsToReady = millisecondsToReady
        self.lastFrameAgeMilliseconds = lastFrameAgeMilliseconds
        self.lastPongAgeMilliseconds = lastPongAgeMilliseconds
        self.roundTripMilliseconds = roundTripMilliseconds
    }

    /// Times are monotonic seconds. An age is clamped at zero so a clock read slightly earlier than the stamp cannot go negative.
    public static func make(
        trackedStage: ConnectStage, reason: ClientSession.FailureReason, detail: TransportErrorDetail?,
        now: TimeInterval, lastPictureAt: TimeInterval?, lastReplyAt: TimeInterval?,
        roundTripMilliseconds: Double?, millisecondsToReady: Int?
    ) -> FailureDiagnosis {
        func age(_ stamp: TimeInterval?) -> Int? {
            stamp.map { max(0, Int(((now - $0) * 1000).rounded())) }
        }
        return FailureDiagnosis(
            stage: .atFailure(tracked: trackedStage, reason: reason, detail: detail),
            detail: detail,
            millisecondsToReady: millisecondsToReady,
            lastFrameAgeMilliseconds: age(lastPictureAt),
            lastPongAgeMilliseconds: age(lastReplyAt),
            roundTripMilliseconds: roundTripMilliseconds.map { Int($0.rounded()) }
        )
    }
}

extension ClientSession {
    /// Called with `lock` held, before `stopVideoWatchLocked()` clears the stamps it reads.
    func diagnosisLocked(reason: FailureReason, detail: TransportErrorDetail?) -> FailureDiagnosis {
        FailureDiagnosis.make(
            trackedStage: connectStage, reason: reason, detail: detail,
            now: Self.monotonicNow(),
            lastPictureAt: videoDelivery.firstPictureMilliseconds == nil ? nil : lastPictureAt,
            lastReplyAt: lastControlReplyAt,
            roundTripMilliseconds: latency.reported,
            millisecondsToReady: _millisecondsToReady
        )
    }

    /// Called with `lock` held when the handshake completes.
    func noteReadyLocked(at now: TimeInterval) {
        connectStage = .ready
        _millisecondsToReady = connectStartedAt.map { Int(((now - $0) * 1000).rounded()) }
    }
}
