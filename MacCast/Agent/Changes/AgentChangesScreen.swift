import MacCastKit
import RemoteCore
import SwiftUI

/// The project's files with the ones that changed lit, and a way to review them from the phone.
struct AgentChangesScreen: View {
    let sessionID: UUID

    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var review = AgentChangesReview()
    @State private var edits: [AgentFileEdit] = []
    @State var overview = AgentChangeOverview(report: nil, edits: [])
    @State private var showsCommit = false
    @State var showsFilters = false
    @State var search = ""
    @Bindable private var filters = AgentReviewFilterStore.shared

    private var session: RemoteAgentSession? {
        model.agentSessions.first { $0.id == sessionID }
    }

    private var report: AgentChangesReport? { model.agentChanges(for: sessionID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    if report == nil && overview.entries.isEmpty && overview.hiddenCount == 0 {
                        waiting
                    } else {
                        if overview.hiddenCount > 0 { hiddenRow(overview.hiddenCount) }
                        modePicker
                        list
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showsCommit = true } label: { Image(systemName: "checkmark.circle") }
                        .accessibilityLabel(Text("Commit"))
                        .disabled(report?.isRepository != true)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showsFilters = true } label: {
                        Image(systemName: filters.filter.isDefault
                            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel(Text("Filters"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.loadAgentChanges(sessionID) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(Text("Refresh"))
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search files"))
            .navigationDestination(for: String.self) { path in
                if let entry = overview.entry(at: path) {
                    AgentChangeFileScreen(entry: entry, review: review)
                }
            }
            .safeAreaInset(edge: .bottom) { sendBar }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsCommit) {
            AgentCommitSheet(sessionID: sessionID, filter: filters.filter, agentEditedPaths: Set(edits.map(\.path)))
        }
        .sheet(isPresented: $showsFilters) { AgentReviewFilterSheet(filter: $filters.filter, offersAgentRule: true) }
        .onAppear {
            model.loadAgentChanges(sessionID)
            refreshEdits()
            rebuild()
        }
        .onChange(of: session?.transcript.lastIndex) { refreshEdits() }
        .onChange(of: report) { rebuild() }
        .onChange(of: edits) { rebuild() }
        .onChange(of: filters.filter) { rebuild() }
        .onChange(of: search) { rebuild() }
    }

    private func refreshEdits() {
        guard let session else { return }
        let found = AgentChangeSet.edits(in: session.transcript, directory: session.directory)
        if found != edits { edits = found }
    }

    private func rebuild() {
        overview = AgentChangeOverview(report: report, edits: edits, filter: filters.filter, search: search)
        review.openFoldersWithChanges(of: overview.tree)
    }

    private var sendBar: some View {
        Group {
            if !review.comments.isEmpty {
                Button(action: sendReview) {
                    Label("Send \(review.comments.count) comments to the agent", systemImage: "paperplane")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ColorPalette.onInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(ColorPalette.ink, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ColorPalette.backdrop.opacity(0.9))
            }
        }
    }

    private func sendReview() {
        model.sendAgentPrompt(AgentReviewPrompt.text(for: review.comments), to: sessionID)
        review.comments = []
        dismiss()
    }
}
