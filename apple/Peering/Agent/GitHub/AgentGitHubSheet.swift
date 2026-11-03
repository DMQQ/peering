import PeeringKit
import RemoteCore
import SwiftUI

/// The chat's branch on GitHub, read and acted on through the Mac's own `gh`. Every action asks for Face ID first.
struct AgentGitHubSheet: View {
    let sessionID: UUID

    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var mergeMethod: AgentGitHubMergeMethod = .squash
    @State private var pending: AgentGitHubAction?

    private var report: AgentGitHubReport? { model.agentGitHub(for: sessionID) }
    private var busy: AgentGitHubAction? { model.agentGitHubBusy(for: sessionID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let result = model.agentGitHubResult(for: sessionID) { resultCard(result) }
                    if let report {
                        if let problem = report.problem {
                            card { Text(verbatim: HostWireText.localized(problem)).font(.subheadline).foregroundStyle(.secondary) }
                        } else {
                            pullRequestCard(report)
                            if !report.runs.isEmpty { runsCard(report.runs) }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.loadAgentGitHub(sessionID) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
            .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible) {
                Button(confirmationButton) { authorize() }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.loadAgentGitHub(sessionID) }
    }

    // MARK: - Cards

    @ViewBuilder
    private func pullRequestCard(_ report: AgentGitHubReport) -> some View {
        card {
            if let pullRequest = report.pullRequest {
                Button { open(pullRequest.url) } label: {
                    Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ColorPalette.ink).multilineTextAlignment(.leading)
                }
                Text(statusLine(pullRequest)).font(.subheadline).foregroundStyle(.secondary)
                if AgentGitHubOffer.canMerge(pullRequest) {
                    Picker("Merge method", selection: $mergeMethod) {
                        ForEach(AgentGitHubMergeMethod.allCases, id: \.self) { Text(methodName($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    actionButton("Merge", action: .merge(number: pullRequest.number, headCommit: pullRequest.headCommit, method: mergeMethod))
                }
            } else {
                Text(report.branch.map { String(localized: "No pull request for \($0) yet.") } ?? String(localized: "No pull request yet.")).font(.subheadline).foregroundStyle(.secondary)
                if AgentGitHubOffer.canCreatePullRequest(report) {
                    actionButton("Open a pull request", action: .createPullRequest(draft: false))
                }
            }
        }
    }

    private func runsCard(_ runs: [AgentGitHubRun]) -> some View {
        card {
            Text("Workflow runs").font(.system(size: 15, weight: .semibold)).foregroundStyle(ColorPalette.ink)
            ForEach(runs) { run in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: run)).foregroundStyle(AgentGitHubOffer.tone(of: run) == .failed ? ColorPalette.danger : ColorPalette.ink)
                    Button { open(run.url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: run.name).font(.subheadline.weight(.medium)).foregroundStyle(ColorPalette.ink)
                            Text(verbatim: run.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if AgentGitHubOffer.canRerun(run) {
                        Button("Re-run failed") { pending = .rerunFailedJobs(runID: run.id) }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(ColorPalette.ink)
                            .disabled(busy != nil)
                    }
                }
            }
        }
    }

    private func resultCard(_ result: AgentGitHubResult) -> some View {
        card {
            Label(result.succeeded ? "Done" : "That did not happen", systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(ColorPalette.ink)
            Text(verbatim: HostWireText.localized(result.message)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    private func actionButton(_ title: LocalizedStringKey, action: AgentGitHubAction) -> some View {
        let isBusy = busy == action
        return Button { pending = action } label: {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(ColorPalette.onInk) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(ColorPalette.onInk)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(ColorPalette.ink.opacity(busy == nil ? 1 : 0.35), in: Capsule())
        }
        .disabled(busy != nil)
    }

    // MARK: - Text

    private func statusLine(_ pullRequest: AgentGitHubPullRequest) -> String {
        let parts = AgentGitHubOffer.facts(about: pullRequest).map { fact in
            switch fact {
            case .merged: String(localized: "Merged")
            case .closed: String(localized: "Closed")
            case .draft: String(localized: "Draft")
            case .conflicting: String(localized: "Has conflicts")
            case .checksFailing(let count): String(localized: "\(count) checks failing")
            case .checksRunning(let count): String(localized: "\(count) checks running")
            case .checksPassed: String(localized: "All checks passed")
            case .approved: String(localized: "Approved")
            case .changesRequested: String(localized: "Changes requested")
            }
        }
        return parts.isEmpty ? String(localized: "Open") : parts.joined(separator: " · ")
    }

    private func methodName(_ method: AgentGitHubMergeMethod) -> String {
        switch method {
        case .squash: String(localized: "Squash")
        case .merge: String(localized: "Merge")
        case .rebase: String(localized: "Rebase")
        }
    }

    private func symbol(for run: AgentGitHubRun) -> String {
        switch AgentGitHubOffer.tone(of: run) {
        case .passed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .running: "clock"
        case .other: "minus.circle"
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmationTitle: String {
        switch pending {
        case .merge(let number, _, let method): String(localized: "Merge #\(number) (\(methodName(method)))?")
        case .createPullRequest: String(localized: "Open a pull request from this branch's commits?")
        case .rerunFailedJobs: String(localized: "Re-run the failed jobs?")
        case nil: ""
        }
    }

    private var confirmationButton: LocalizedStringKey {
        switch pending {
        case .merge: "Merge"
        case .createPullRequest: "Open pull request"
        case .rerunFailedJobs, nil: "Re-run"
        }
    }

    // MARK: - Acting

    /// Face ID, or the passcode, before anything reaches GitHub; a phone with neither set up has only the confirmation.
    private func authorize() {
        guard let action = pending else { return }
        pending = nil
        Task {
            if DeviceAuthentication.isAvailable {
                guard await DeviceAuthentication.authenticate(reason: String(localized: "Confirm this GitHub action on your Mac.")) else { return }
            }
            model.performAgentGitHub(action, for: sessionID)
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address), url.scheme == "https" else { return }
        openURL(url)
    }
}
