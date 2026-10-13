import Foundation
import PeeringKit
import os

/// The Mac host's failure events. Call sites pass a code from a closed set and, at most, a number: never an error message, a path, a name or an address.
enum HostTelemetry {
    private static let limiter = OSAllocatedUnfairLock(initialState: HostErrorLimiter())

    /// At most one event per code per minute; `count` says how many occurrences it stands for. `sessionRef` is the phone's tag when the failure happened inside a session it opened.
    static func error(
        _ code: HostEventCodes.ErrorCode, stage: HostEventCodes.ErrorStage? = nil, errorCode: Int? = nil, recovered: Bool? = nil, sessionRef: String? = nil
    ) {
        guard let count = limiter.withLock({ $0.admit(code, at: .now) }) else { return }
        var properties: [String: Any] = ["code": code.rawValue, "count": count]
        if let stage { properties["stage"] = stage.rawValue }
        if let errorCode { properties["error_code"] = errorCode }
        if let recovered { properties["recovered"] = recovered }
        if let sessionRef = sessionRef ?? HostSessionFacts.shared.soleSessionRef { properties["session_ref"] = sessionRef }
        Analytics.send("host_error", properties)
    }

    /// The numeric part of an error worth keeping: the code, whatever the domain.
    static func errorCode(of error: Error) -> Int {
        (error as NSError).code
    }
}
