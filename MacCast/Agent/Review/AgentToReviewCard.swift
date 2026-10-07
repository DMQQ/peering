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
                titleBar(queue)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                AgentToReviewPreview(
                    files: model.isAgentHostReachable ? queue.pendingPreview : [],
                    more: queue.pendingFileCount - queue.pendingPreview.count,
                    note: screenNote(queue)
                )
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

    /// The same title bar as a terminal's window: three dots, the name with a line under it, and what is there to see on the right.
    private func titleBar(_ queue: AgentReviewQueue) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.white.opacity(0.16)).frame(width: 8, height: 8)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("To review")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                Text("^[\(queue.pendingFileCount) file](inflect: true) in ^[\(queue.pendingChatCount) chat](inflect: true)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.isAgentHostReachable {
                let stats = queue.pendingStats
                DiffCounts(added: stats.added, removed: stats.removed, font: .system(size: 11, weight: .semibold, design: .monospaced))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.white.opacity(0.04))
    }

    /// What the screen says when there are no files to list.
    private func screenNote(_ queue: AgentReviewQueue) -> String? {
        if !model.isAgentHostReachable { return String(localized: "Your Mac is not reachable, so this may be out of date") }
        let missing = queue.unansweredChatCount
        return missing > 0 ? String(localized: "\(missing) not checked yet") : nil
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
