import Foundation
import PeeringKit
import RemoteCore

/// Maps errors the host already handles onto the closed codes of ``HostEventCodes/ErrorCode``, so a call site is one line.
extension HostTelemetry {
    /// A capture failure as the coordinator reports it. A system-stopped stream keeps its `SCStreamError` code.
    static func capture(_ failure: CaptureError) {
        switch failure {
        case .screenRecordingDenied: error(.permissionRevoked, stage: .capture)
        case .streamStopped(let code, _): error(.captureStopped, stage: .stream, errorCode: code)
        case .encodingFailed: error(.encoderFailed, stage: .encode)
        case .recoveryFailed: error(.captureFailed, stage: .recovery, recovered: false)
        case .sourceUnavailable, .catalogUnavailable, .streamFailed: error(.captureFailed, stage: .start)
        }
    }

    /// The relay connection ended: refused by the relay while registering, or lost afterwards. A socket the network dropped is not reported: one Mac sent it 87 times in a day.
    static func relay(_ failure: Error) {
        let code = errorCode(of: failure)
        if case RelaySignallingError.refused = failure {
            error(.relayRegistrationFailed, stage: .register, errorCode: code)
        } else if !ErrorReportFilter.isNetworkWeather(failure as NSError) {
            error(.relayDisconnected, stage: .connection, errorCode: code)
        }
    }

    /// Every error the host reports through ``Analytics/failed(_:in:context:)`` that has a code of its own, so none of those call sites changes.
    static func handled(_ failure: Error, in area: Analytics.Area) {
        let code = errorCode(of: failure)
        switch area {
        case .capture:
            if let capture = failure as? CaptureError { Self.capture(capture) } else { error(.captureFailed, stage: .capture, errorCode: code) }
        case .display: error(.virtualDisplayFailed, stage: .display, errorCode: code)
        case .agent: error(.agentCrashed, stage: .agent, errorCode: code)
        case .fileTransfer: error(.fileTransferFailed, stage: .fileTransfer, errorCode: code)
        case .permission: error(.permissionRevoked, stage: .permission, errorCode: code)
        case .network, .relay, .terminal, .sleepPrevention, .launchAtLogin, .appLaunching, .update: break
        }
    }
}

extension HostTelemetry {
    static func pairingRefused(stage: HostEventCodes.ErrorStage) { error(.pairingRefused, stage: stage) }

    static func hookInstallFailed(_ failure: Error) { error(.hookInstallFailed, errorCode: errorCode(of: failure)) }
}
