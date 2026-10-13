import PeeringKit
import RemoteCore
import SwiftUI

struct AgentHistoryLoading: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white.opacity(0.7))
            Text("Loading the conversation")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
