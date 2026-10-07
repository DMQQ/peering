import MacCastKit
import RemoteCore
import SwiftUI

/// A quiet row on the Agents page: how many changed files across the open chats are still waiting for a look. Absent when nothing is.
struct AgentToReviewCard: View {
    @Environment(SessionModel.self) private var model
    @State private var inbox = AgentReviewInbox()
    @State private var showsList = false

    private var queue: AgentReviewQueue {
        AgentReviewQueue(sources: model.agentReviewSources(), marks: inbox.marks, filter: inbox.filter)
    }

    private var turnStates: [UUID: AgentSessionState] {
        Dictionary(model.agentCards.filter(\.isLive).map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let current = queue
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if current.pendingFileCount > 0 || current.groups.contains(where: { $0.status == .unreachable && !$0.files.isEmpty }) {
                row(current)
                    .padding(.top, 20)
                    .transition(Self.arrival)
            } else if isChecking(current) {
                AgentToReviewPlaceholder()
                    .padding(.top, 20)
                    .transition(.opacity)
            }
        }
        .animation(Self.arrivalSpring, value: current.pendingFileCount > 0)
        .animation(Motion.settle, value: isChecking(current))
        .onAppear { ask(.hubAppeared) }
        .onChange(of: model.agentCards.filter(\.isLive).map(\.id)) { _, _ in ask(.hubAppeared) }
        .onChange(of: model.isAgentHostReachable) { _, reachable in if reachable { ask(.hubAppeared) } }
        .onChange(of: turnStates) { old, new in
            let finished = new.filter { id, state in
                state == .idle && (old[id] == .working || old[id] == .awaitingApproval)
            }
            if !finished.isEmpty { ask(.turnFinished, among: Array(finished.keys)) }
            inbox.forgetChats(except: Set(new.keys))
        }
        .onChange(of: model.activeSession?.agentChanges) { _, reports in
            for (chat, report) in reports ?? [:] { inbox.absorb(report, from: chat) }
        }
        .sheet(isPresented: $showsList) { AgentReviewScreen(inbox: inbox) }
    }

    /// Rises into place out of a blur, as the terminal cards do, instead of switching on.
    private static let arrival = AnyTransition.modifier(
        active: ArrivalEffect(progress: 0), identity: ArrivalEffect(progress: 1)
    )
    private static let arrivalSpring = Animation.spring(response: 0.5, dampingFraction: 0.78)

    /// Room held for the answer while the Mac is still being asked, so the page below does not jump when it arrives.
    private func isChecking(_ queue: AgentReviewQueue) -> Bool {
        model.isAgentHostReachable && queue.groups.contains { $0.status == .unknown || $0.status == .checking }
    }

    private func ask(_ reason: AgentReviewRefreshPolicy.Reason, among chats: [UUID]? = nil) {
        guard model.isAgentHostReachable else { return }
        let candidates = chats ?? model.agentCards.filter(\.isLive).map(\.id)
        for chat in inbox.chatsToAsk(candidates, reason: reason) { model.loadAgentChanges(chat) }
    }

    private func row(_ queue: AgentReviewQueue) -> some View {
        Button { showsList = true } label: {
            VStack(spacing: 0) {
                header(queue)
                if model.isAgentHostReachable, !queue.pendingPreview.isEmpty {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    AgentToReviewPreview(files: queue.pendingPreview, more: queue.pendingFileCount - queue.pendingPreview.count)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("to-review-card")
    }

    private func header(_ queue: AgentReviewQueue) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.14))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("To review")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                detail(queue)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(12)
    }

    @ViewBuilder
    private func detail(_ queue: AgentReviewQueue) -> some View {
        if !model.isAgentHostReachable {
            Text("Your Mac is not reachable, so this may be out of date")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            let stats = queue.pendingStats
            let missing = queue.unansweredChatCount
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(queue.pendingFileCount) file](inflect: true) in ^[\(queue.pendingChatCount) chat](inflect: true)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if stats.added > 0 || stats.removed > 0 || missing > 0 {
                    HStack(spacing: 8) {
                        DiffCounts(added: stats.added, removed: stats.removed)
                        if missing > 0 {
                            Text("\(missing) not checked yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }
        }
    }
}

private struct ArrivalEffect: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .offset(y: (1 - progress) * 22)
            .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
    }
}
