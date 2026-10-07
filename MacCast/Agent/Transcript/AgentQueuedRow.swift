import MacCastKit
import RemoteCore
import SwiftUI

struct AgentQueuedRow: View {
    let text: String
    let position: Int
    let total: Int
    let remove: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 5) {
                AgentPlainText(text: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .opacity(0.6)
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .symbolEffect(.pulse)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            }
            .contextMenu {
                Button("Remove from queue", systemImage: "xmark", role: .destructive, action: remove)
                    .menuDanger()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Queued, not started yet"))
    }

    private var label: LocalizedStringKey {
        total > 1 ? "Queued, \(position) of \(total), not started" : "Queued, starts when this turn ends"
    }
}
