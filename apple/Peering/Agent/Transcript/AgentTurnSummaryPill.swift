import MacCastKit
import RemoteCore
import SwiftUI

struct AgentTurnSummaryPill: View {
    let summary: AgentTurnSummary

    var body: some View {
        HStack(spacing: 6) {
            if summary.stopped {
                Text("Stopped")
            } else if !summary.ok {
                Text("Failed")
                    .foregroundStyle(ColorPalette.danger)
            }
            if let cost = summary.costUSD {
                Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
            }
            if let input = summary.inputTokens, let output = summary.outputTokens {
                Text("\(input) in / \(output) out")
            }
            if let duration = summary.duration {
                Text(TerminalCommandFinishDetector.spokenDuration(duration))
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white.opacity(0.45))
        .padding(.top, 2)
    }
}
