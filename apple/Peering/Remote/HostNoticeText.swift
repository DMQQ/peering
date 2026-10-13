import Foundation
import RemoteCore

/// What the phone says for a condition the Mac named. The Mac's own sentence is English, so it is only the fallback for a payload with no code, or a code from a newer Mac.
enum HostNoticeText {
    static func message(for notice: NoticePayload) -> String? {
        guard let message = notice.message else { return nil }
        guard let code = notice.knownCode else { return message }
        switch code {
        case .captureRecoveryFailed:
            return String(localized: "The picture stopped and this Mac could not start it again. Reconnect to try once more, or check Screen Recording and the display on the Mac.")
        case .screenRecordingDenied:
            return String(localized: "This Mac cannot record its screen. Someone there has to allow Screen Recording for Peering in System Settings, then quit Peering on the Mac and open it again.")
        case .screenLocked:
            return String(localized: "This Mac is locked.")
        case .displayDisconnected:
            return String(localized: "That display is no longer connected. Choose another from Sources.")
        case .screenAsleep:
            return String(localized: "This Mac's screen is asleep.")
        case .privacyModeFailed:
            return String(localized: "Privacy Mode could not darken this Mac's displays.")
        case .privacyModeUncovered:
            return String(localized: "Some of this Mac's displays are still visible: Privacy Mode could not cover them.")
        }
    }
}
