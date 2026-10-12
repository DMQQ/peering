import Foundation
import RemoteCore

/// What a `peering://` link asks for. Any page or app can open one, so what runs is decided here and not at the call site.
public enum URLCommand: Equatable, Sendable {
    case connect(hostID: String?)
    case chat(chatID: UUID, hostID: String?)
    case pairingCode(URL)
    case disconnect
    case endShells
}

public enum URLCommandPolicy {
    public enum Decision: Equatable, Sendable {
        case run
        /// Ends something the user may not want ended, so a person is asked first.
        case confirm
        /// The app lock is up: kept, and run once it opens.
        case holdUntilUnlock
    }

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme == "peering" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        func value(_ name: String) -> String? { items?.first { $0.name == name }?.value }

        switch url.host {
        case "connect":
            return .connect(hostID: value("id"))
        case "chat":
            guard let chatID = value("id").flatMap(UUID.init(uuidString:)) else { return nil }
            return .chat(chatID: chatID, hostID: value("host"))
        case PairingPayload.codeHost:
            return .pairingCode(url)
        case "disconnect":
            return .disconnect
        case "end-shells":
            return .endShells
        default:
            return nil
        }
    }

    /// Nothing runs behind the lock. Ending a session or shells asks only when there is something to end.
    public static func decide(
        _ command: URLCommand,
        isLocked: Bool,
        hasLiveSession: Bool,
        hasLiveShells: Bool
    ) -> Decision {
        if isLocked { return .holdUntilUnlock }
        switch command {
        case .disconnect: return hasLiveSession ? .confirm : .run
        case .endShells: return hasLiveShells ? .confirm : .run
        case .connect, .chat, .pairingCode: return .run
        }
    }
}
