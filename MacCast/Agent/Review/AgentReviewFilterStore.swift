import Foundation
import MacCastKit
import Observation
import OSLog

private let filterLog = Logger(subsystem: "pl.dmq.peering", category: "agent-review")

/// The one saved filter, read by To review and by every chat's Changes screen.
@MainActor @Observable
final class AgentReviewFilterStore {
    static let shared = AgentReviewFilterStore()

    private static let key = "Peering.agentReviewFilter"

    var filter: AgentReviewFilter {
        didSet { if filter != oldValue { save() } }
    }

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
        filter = stored.flatMap { try? JSONDecoder().decode(AgentReviewFilter.self, from: $0) } ?? AgentReviewFilter()
    }

    private func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(filter), forKey: Self.key)
        } catch {
            filterLog.error("Could not save review filter: \(error.localizedDescription, privacy: .public)")
        }
    }
}
