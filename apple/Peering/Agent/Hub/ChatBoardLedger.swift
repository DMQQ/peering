import Foundation
import Observation
import PeeringKit
import RemoteCore

/// One clock for every Mac's chats: a chat's ID is unique across Macs, and the board reads them all at once.
@MainActor
@Observable
final class ChatBoardLedger {
    static let shared = ChatBoardLedger()

    private(set) var clock = ChatChangeClock()

    /// `liveChats` is every Mac's chats, since one Mac's cards arrive without the others'. Assigned only on a change, so a recompute that changes nothing does not invalidate the board.
    func observe(_ cards: [AgentCardDigest], liveChats: Set<UUID>, at now: Date = .now) {
        var next = clock
        for card in cards {
            next.observe(card.id, fingerprint: Self.fingerprint(card), at: now)
        }
        next.keepOnly(liveChats)
        if next != clock { clock = next }
    }

    func markSeen(_ id: UUID, at now: Date = .now) {
        clock.markSeen(id, at: now)
    }

    private static func fingerprint(_ card: AgentCardDigest) -> String {
        "\(card.state.rawValue)|\(card.isPaused)|\(card.preview ?? "")"
    }
}
