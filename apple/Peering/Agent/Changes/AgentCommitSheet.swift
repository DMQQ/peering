import PeeringKit
import RemoteCore
import SwiftUI

/// Commit chosen files, then, as a step of its own, push. The Mac decides what git runs; this only asks.
struct AgentCommitSheet: View {
    let sessionID: UUID
    /// The Changes screen's filter: what it hides stays out of the commit unless ticked here.
    let filter: AgentReviewFilter
    let agentEditedPaths: Set<String>

    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = AgentCommitSelection()
    @State private var showsHidden = false
    @State private var message = ""
    @State private var messageEdited = false
    @State private var confirmsCommit = false
    @State private var confirmsPush = false

    private var report: AgentChangesReport? { model.agentChanges(for: sessionID) }
    private var files: [AgentChangedFile] { report?.files ?? [] }
    private var visibleFiles: [AgentChangedFile] { files.filter { !isHidden($0) } }
    private var hiddenFiles: [AgentChangedFile] { files.filter(isHidden) }
    private var chosen: [AgentChangedFile] { selection.chosen(from: files, isHidden: isHidden) }
    private func isHidden(_ file: AgentChangedFile) -> Bool {
        !filter.shows(file, editedByAgent: agentEditedPaths.contains(file.path))
    }

    private var busy: AgentGitOperation? { model.agentGitBusy(for: sessionID) }
    private var result: AgentGitResult? { model.agentGitResult(for: sessionID) }
    private var draft: String { AgentCommitDraft.message(for: chosen) }
    private var canCommit: Bool {
        busy == nil && !chosen.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    commitCard
                    if let result { resultCard(result) }
                    pushCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { message = draft }
        .onChange(of: chosen.map(\.path)) { if !messageEdited { message = draft } }
        .onChange(of: result) { resetAfterCommit() }
    }

    private var commitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files to include").font(.system(size: 15, weight: .semibold)).foregroundStyle(ColorPalette.ink)
            if files.isEmpty {
                Text("Nothing has changed in this folder.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(visibleFiles, id: \.path) { file in fileRow(file, hidden: false) }
            if !hiddenFiles.isEmpty { hiddenSection }
            TextField("Commit message", text: $message, axis: .vertical)
                .lineLimit(2...8)
                .font(.system(size: 15))
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16)))
                .onChange(of: message) { if message != draft { messageEdited = true } }
            primaryButton(
                busy == .commit ? "Committing" : "Commit \(chosen.count) files", isBusy: busy == .commit, isEnabled: canCommit
            ) { confirmsCommit = true }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .confirmationDialog(commitTitle, isPresented: $confirmsCommit, titleVisibility: .visible) {
            Button("Commit") {
                model.commitAgentChanges(sessionID, paths: chosen.map(\.path), message: message)
            }
        }
    }

    private var commitTitle: String {
        let branch = report?.branch?.head ?? String(localized: "this folder")
        return String(localized: "Commit \(chosen.count) files to \(branch)?")
    }

    private var hiddenSection: some View {
        let included = hiddenFiles.filter { selection.isChosen($0, hidden: true) }.count
        return VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsHidden.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.system(size: 12, weight: .semibold))
                    Text(hiddenSummary(included: included)).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text(showsHidden ? "Hide" : "Show").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("commit-hidden-row")
            if showsHidden { ForEach(hiddenFiles, id: \.path) { file in fileRow(file, hidden: true) } }
        }
    }

    private func hiddenSummary(included: Int) -> String {
        included == 0
            ? String(localized: "\(hiddenFiles.count) hidden by filters are not included")
            : String(localized: "\(hiddenFiles.count) hidden by filters, \(included) included")
    }

    private func fileRow(_ file: AgentChangedFile, hidden: Bool) -> some View {
        let isChosen = selection.isChosen(file, hidden: hidden)
        return Button {
            selection.toggle(file, hidden: hidden)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.white.opacity(isChosen ? 0.95 : 0.4))
                Text(verbatim: file.path).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(ColorPalette.ink).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text(verbatim: file.kind == .untracked ? "U" : "+\(file.added) -\(file.removed)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resultCard(_ result: AgentGitResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(resultTitle(result), systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(ColorPalette.ink)
            Text(verbatim: HostWireText.localized(result.message)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    private func resultTitle(_ result: AgentGitResult) -> LocalizedStringKey {
        switch (result.operation, result.succeeded) {
        case (.commit, true): "Committed"
        case (.commit, false): "The commit did not happen"
        case (.push, true): "Pushed"
        case (.push, false): "The push did not happen"
        }
    }

    @ViewBuilder
    private var pushCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Push").font(.system(size: 15, weight: .semibold)).foregroundStyle(ColorPalette.ink)
            switch AgentGitPush.offer(for: report?.branch) {
            case .ready(let branch, let upstream, let ahead):
                Text("\(ahead) commits on \(branch) are not on \(upstream) yet.").font(.subheadline).foregroundStyle(.secondary)
                primaryButton(busy == .push ? "Pushing" : "Push", isBusy: busy == .push, isEnabled: busy == nil) { confirmsPush = true }
                    .confirmationDialog(
                        String(localized: "Push \(branch) to \(upstream)?"), isPresented: $confirmsPush, titleVisibility: .visible
                    ) {
                        Button("Push") { model.pushAgentChanges(sessionID) }
                    }
            case .nothingToPush:
                Text("Everything on this branch is already pushed.").font(.subheadline).foregroundStyle(.secondary)
            case .blocked(let reason):
                Text(verbatim: HostWireText.localized(reason)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    private func primaryButton(_ title: LocalizedStringKey, isBusy: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(ColorPalette.onInk) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(ColorPalette.onInk)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(ColorPalette.ink.opacity(isEnabled ? 1 : 0.35), in: Capsule())
        }
        .disabled(!isEnabled)
    }

    private func resetAfterCommit() {
        guard result?.operation == .commit, result?.succeeded == true else { return }
        messageEdited = false
        selection.reset()
        message = draft
    }
}
