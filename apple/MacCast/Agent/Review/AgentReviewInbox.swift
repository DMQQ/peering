import Foundation
import MacCastKit
import Observation
import OSLog
import RemoteCore

private let reviewLog = Logger(subsystem: "pl.dmq.peering", category: "agent-review")

/// What the cross-chat review list remembers: which files are marked reviewed, the comments written per chat, and when each chat was last asked.
@MainActor @Observable
final class AgentReviewInbox {
    private static let storeKey = "Peering.agentReviewMarks"

    private(set) var marks: AgentReviewMarks
    var filter: AgentReviewFilter {
        get { AgentReviewFilterStore.shared.filter }
        set { AgentReviewFilterStore.shared.filter = newValue }
    }
    private var reviews: [UUID: AgentChangesReview] = [:]
    @ObservationIgnored private var policy = AgentReviewRefreshPolicy()

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.storeKey)
        marks = stored.flatMap { try? JSONDecoder().decode(AgentReviewMarks.self, from: $0) } ?? AgentReviewMarks()
    }

    /// One chat's comments and open folders, kept here so they outlive the screens that edit them.
    func review(for chat: UUID) -> AgentChangesReview {
        if let existing = reviews[chat] { return existing }
        let made = AgentChangesReview()
        reviews[chat] = made
        return made
    }

    func setReviewed(_ reviewed: Bool, _ file: AgentChangedFile, in chat: UUID) {
        marks.setReviewed(reviewed, file, in: chat)
        save()
    }

    func absorb(_ report: AgentChangesReport, from chat: UUID) {
        let before = marks
        marks.prune(chat: chat, against: report)
        if marks != before { save() }
    }

    func forgetChats(except live: Set<UUID>) {
        let before = marks
        marks.retain(chats: live)
        reviews = reviews.filter { live.contains($0.key) }
        policy.forget(except: live)
        if marks != before { save() }
    }

    /// The chats the Mac should be asked about now, already recorded as asked.
    func chatsToAsk(_ chats: [UUID], reason: AgentReviewRefreshPolicy.Reason) -> [UUID] {
        policy.chatsToAsk(chats, reason: reason, now: ContinuousClock.now)
    }

    func sendPlan(for chats: [AgentCardDigest]) -> AgentReviewSendPlan {
        AgentReviewSendPlan(chats: chats.map { ($0.id, $0.title, review(for: $0.id).comments) })
    }

    func rejection(for chats: [AgentCardDigest], selection: Set<AgentReviewTarget>, reason: String = "") -> AgentReviewRejection {
        AgentReviewRejection(chats: chats.map { ($0.id, $0.title, review(for: $0.id).comments) }, selection: selection, reason: reason)
    }

    private func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(marks), forKey: Self.storeKey)
        } catch {
            reviewLog.error("Could not save review marks: \(error.localizedDescription, privacy: .public)")
        }
    }
}
