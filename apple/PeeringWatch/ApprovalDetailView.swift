import SwiftUI
import WatchLink

struct ApprovalDetailView: View {
    @Environment(ApprovalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let approval: WatchApproval

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !approval.body.isEmpty {
                    Text(approval.body)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                answers
                if let failure = store.failure { FailureNote(failure: failure) }
            }
        }
        .navigationTitle(approval.chatTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        Group {
            if let host = approval.hostName {
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var answers: some View {
        let choices = approval.choices(allowTitle: String(localized: "Allow"), denyTitle: String(localized: "Deny"))
        if choices.isEmpty {
            Label("Open Peering on your iPhone to answer this one.", systemImage: "iphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if store.sending.contains(approval.approvalID) {
            ProgressView("Sending…")
        } else {
            ForEach(choices) { choice in
                Button(choice.label) { send(choice) }
                    .buttonStyle(.bordered)
                    .tint(isAllow(choice) ? .blue : nil)
            }
        }
    }

    private func isAllow(_ choice: WatchApproval.Choice) -> Bool {
        approval.kind == .allowDeny && choice.actionIdentifier == WatchApproval.allowIdentifier
    }

    private func send(_ choice: WatchApproval.Choice) {
        Task {
            if await store.answer(approval, with: choice) { dismiss() }
        }
    }
}

private struct FailureNote: View {
    let failure: ApprovalStore.Failure

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var message: String {
        switch failure {
        case .phoneNotReachable: String(localized: "Your iPhone is not reachable. Open Peering on it and try again.")
        case .notTaken: String(localized: "The Mac did not take the answer. Try again, or answer on your iPhone.")
        }
    }
}
