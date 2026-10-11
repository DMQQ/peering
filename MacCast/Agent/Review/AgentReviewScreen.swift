import MacCastKit
import RemoteCore
import SwiftUI

/// Every chat's changed files in one list, with the same diff and comment screens as a single chat's Changes.
struct AgentReviewScreen: View {
    @Bindable var inbox: AgentReviewInbox

    @Environment(SessionModel.self) var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSendAll = false
    @State var confirmsReject = false
    @State var rejectionReason = ""
    @State var selection: Set<AgentReviewTarget> = []
    @State private var search = ""
    @State var showsFilters = false

    var queue: AgentReviewQueue {
        AgentReviewQueue(sources: model.agentReviewSources(), marks: inbox.marks, filter: inbox.filter, search: search)
    }

    private var plan: AgentReviewSendPlan { inbox.sendPlan(for: model.agentCards.filter(\.isLive)) }

    var body: some View {
        let current = queue
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary(current)
                    if current.hiddenFileCount > 0 { hiddenRow(current.hiddenFileCount) }
                    if current.visibleGroups.isEmpty {
                        Text("Nothing is waiting for review.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(current.visibleGroups) { group in groupSection(group) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("To review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: refreshAll) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(Text("Refresh"))
                }
            }
            .navigationDestination(for: AgentReviewTarget.self) { target in fileScreen(target) }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    sendBar
                    if selection.isEmpty {
                        searchBar.transition(.blurReplace)
                    } else {
                        AgentReviewActionBar(
                            count: selection.count, clear: clearSelection,
                            reject: { confirmsReject = true }, markReviewed: { markSelectedReviewed(current) }
                        )
                        .transition(.blurReplace)
                    }
                }
                .animation(Motion.settle, value: selection.isEmpty)
                .reviewBottomBackdrop()
            }
        }
        .preferredColorScheme(.dark)
        .analyticsScreen(.agentReview)
        .sheet(isPresented: $showsFilters) { AgentReviewFilterSheet(filter: $inbox.filter) }
        .confirmationDialog("Send issues to the chats?", isPresented: $confirmsSendAll, titleVisibility: .visible) {
            Button("Send \(plan.commentCount) comments") { sendAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: plan.summary)
        }
        .sheet(isPresented: $confirmsReject) {
            AgentReviewRejectSheet(
                reason: $rejectionReason, fileCount: rejection.fileCount, summary: rejection.summary
            ) { rejectSelected() }
        }
        .onChange(of: current.selectableTargets) { selection = current.retaining(selection) }
        .onAppear { refreshAll() }
    }

    @ViewBuilder
    private func fileScreen(_ target: AgentReviewTarget) -> some View {
        if let report = model.agentChanges(for: target.chatID),
           let entry = AgentChangeSet.entries(report: report, edits: []).first(where: { $0.path == target.path }),
           let file = report.files.first(where: { $0.path == target.path }) {
            AgentChangeFileScreen(entry: entry, review: inbox.review(for: target.chatID))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        let reviewed = inbox.marks.isReviewed(file, in: target.chatID)
                        Button { inbox.setReviewed(!reviewed, file, in: target.chatID) } label: {
                            Image(systemName: reviewed ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .accessibilityLabel(Text(reviewed ? "Mark as not reviewed" : "Mark as reviewed"))
                    }
                }
        }
    }

    /// The search field and the filters button, in the same bottom input as the rest of the app.
    private var searchBar: some View {
        HStack(spacing: 8) {
            InputCapsule {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Search files", text: $search)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("review.search")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 28, height: InputBar.height)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Clear search"))
                }
            }
            filtersButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Glass like the search field beside it; a solid white mark says a filter is on.
    private var filtersButton: some View {
        let isActive = !inbox.filter.isDefaultIgnoringAgentRule
        return Button { showsFilters = true } label: {
            Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: InputBar.height, height: InputBar.height)
                .glassSurface(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .accessibilityLabel(Text("Filters"))
        .accessibilityIdentifier("review.filters")
    }

    private var sendBar: some View {
        Group {
            let plan = plan
            if plan.commentCount > 0 {
                Button { confirmsSendAll = true } label: {
                    Label("Send all issues (\(plan.commentCount))", systemImage: "paperplane")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ColorPalette.onInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(ColorPalette.ink, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func refreshAll() {
        guard model.isAgentHostReachable else { return }
        for chat in model.agentCards.filter(\.isLive).map(\.id) { model.loadAgentChanges(chat) }
    }

    private func sendAll() {
        for item in plan.items {
            model.sendAgentPrompt(item.prompt, to: item.chatID)
            inbox.review(for: item.chatID).comments = []
        }
    }

    func send(_ group: AgentReviewGroup) {
        let review = inbox.review(for: group.chatID)
        guard !review.comments.isEmpty else { return }
        model.sendAgentPrompt(AgentReviewPrompt.text(for: review.comments), to: group.chatID)
        review.comments = []
    }

    func commentCount(in group: AgentReviewGroup) -> Int { inbox.review(for: group.chatID).comments.count }
}
