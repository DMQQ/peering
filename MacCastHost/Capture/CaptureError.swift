import Foundation
import RemoteCore
import ScreenCaptureKit

/// Everything the capture path can fail with, phrased for the status window.
///
/// `-3821` and `-3801` are states the host recovers from rather than fatal errors: the first
/// means the display configuration changed or the Mac woke from sleep, so the stream is rebuilt
/// and the client re-keyed; the second means Screen Recording was never granted, or was revoked
/// between launches. Every other code keeps its own wording, so it stays searchable.
enum CaptureError: LocalizedError, Equatable {
    /// The TCC grant this app needs before a single frame can exist.
    case screenRecordingDenied
    /// The chosen display, application, or window is no longer there.
    case sourceUnavailable(String)
    /// A filter was asked for before the catalogue had been read.
    case catalogUnavailable
    /// The stream stopped on its own; `code` is the raw `SCStreamError` code.
    case streamStopped(code: Int, description: String)
    /// The stream could not be created or started.
    case streamFailed(String)
    /// VideoToolbox refused a frame, or the session could not be created.
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return """
                macOS is not letting this app record the screen. Grant Screen Recording in \
                System Settings → Privacy & Security, then relaunch. Consent is read when \
                the process starts, so a grant made while it is running does nothing.
                """

        case .sourceUnavailable(let detail):
            return detail

        case .catalogUnavailable:
            return "No capture sources have been enumerated yet."

        case .streamStopped(let code, let description):
            return "Capture stopped (\(code)): \(description)"

        case .streamFailed(let detail):
            return "Capture could not start: \(detail)"

        case .encodingFailed(let detail):
            return "The encoder rejected a frame: \(detail)"
        }
    }

/// What the phone is told about this, or nothing when it is not the phone's business.
///
/// A denial is the one failure the phone is otherwise blind to, and it arrives as a connection
/// that works with no frames behind it. The rest either recover by themselves or show as a
/// picture that stopped, which the client already has words for.
    var clientNotice: NoticePayload? {
        switch self {
        case .screenRecordingDenied:
            return NoticePayload(
                message: "This Mac cannot record its screen. Someone there has to allow Screen Recording for Peering in System Settings, then quit Peering on the Mac and open it again.",
                symbol: "rectangle.slash"
            )
        case .sourceUnavailable, .catalogUnavailable, .streamStopped, .streamFailed, .encodingFailed:
            return nil
        }
    }

    /// Translates a thrown `SCStreamError` into the state it implies.
    static func from(_ error: Error) -> CaptureError {
        let nsError = error as NSError
        guard nsError.domain == SCStreamError.errorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code)
        else {
            return .streamFailed(nsError.localizedDescription)
        }

        switch code {
        case .userDeclined:
            return .screenRecordingDenied

        case .systemStoppedStream:
            return .streamStopped(
                code: nsError.code,
                description: """
                    the system stopped it: the display configuration changed, or the Mac \
                    woke from sleep
                    """
            )

        default:
            return .streamStopped(code: nsError.code, description: nsError.localizedDescription)
        }
    }
}
