import Foundation
import RemoteCore
import ScreenCaptureKit

/// Everything the capture path can fail with, phrased for the status window.
///
/// ScreenCaptureKit's codes are mapped rather than passed through because two of them are
/// not really failures at all but *states the host has to recover from*, and a host that
/// treats them as fatal is a host that dies the first time a monitor is unplugged:
///
/// - `-3821` `systemStoppedStream` — the display configuration changed, or the Mac woke
///   from sleep. The stream is gone; a new one has to be built and the client re-keyed.
/// - `-3801` `userDeclined` — Screen Recording was never granted, or was revoked between
///   launches. Nothing will be captured until the user grants it and relaunches.
///
/// Anything else keeps its code and its own wording. A ScreenCaptureKit failure that has
/// been reworded into something friendlier is a failure nobody can search for.
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
    /// **A denial is the one failure the phone is otherwise blind to.** Everything else that goes
    /// wrong with capture either recovers by itself or leaves the client with a catalogue it can
    /// choose from. A missing Screen Recording grant produces a connection that works, a Mac that
    /// says it is serving, and no frames ever, which is exactly what the client renders as
    /// "opening the video channel", indefinitely, with nothing on either screen naming the cause.
    ///
    /// The sentence in ``errorDescription`` is written for the Mac's own window: it can name
    /// System Settings and the pane, because the person reading it is sitting at the machine. This
    /// one is for somebody in another room, who can be told what is wrong and who has to fix it,
    /// and cannot act on a pane they cannot see.
    ///
    /// Nothing else is announced. A source that went away is one the user chose and can see in the
    /// picker, and the two stream failures are either retried by the host or visible as a picture
    /// that stopped, which the client already has words for.
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
