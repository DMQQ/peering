import SwiftUI
import WatchLink

struct ApprovalListView: View {
    @Environment(ApprovalStore.self) private var store
    @State private var path: [WatchApproval] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.approvals.isEmpty {
                    EmptyApprovalsView(phoneReachable: store.phoneReachable)
                } else {
                    List(store.approvals) { approval in
                        NavigationLink(value: approval) { ApprovalRow(approval: approval) }
                    }
                }
            }
            .task {
                guard DemoApprovals.isOn else { return }
                try? await Task.sleep(for: .milliseconds(500))
                path = DemoApprovals.initialPath
            }
            .navigationTitle(Text(verbatim: "Peering"))
            .navigationDestination(for: WatchApproval.self) { approval in
                ApprovalDetailView(approval: approval)
            }
        }
    }
}

private struct ApprovalRow: View {
    let approval: WatchApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(approval.chatTitle)
                .font(.headline)
                .lineLimit(1)
            if let host = approval.hostName {
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(approval.body.isEmpty ? String(localized: "Needs your approval.") : approval.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyApprovalsView: View {
    let phoneReachable: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Nothing waiting")
                .font(.headline)
            Text(phoneReachable
                ? String(localized: "Questions from your agents show up here.")
                : String(localized: "Your iPhone is not reachable. Questions that arrive while it is away still show up here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
