import MacCastKit
import RemoteCore
import SwiftUI

/// The sub-agents working right now, above the composer, so they are in view without scrolling to the call that spawned them.
struct AgentSubagentStrip: View {
    let running: [(call: AgentToolCall, transcript: AgentTranscript)]
    let open: (String) -> Void

    private static let visibleRows = 3

    var body: some View {
        VStack(spacing: 0) {
            ForEach(running.prefix(Self.visibleRows), id: \.call.id) { subagent in
                Button { open(subagent.call.id) } label: {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.mini).tint(.white.opacity(0.7))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(subagent.call.detail ?? String(localized: "Sub-agent"))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(subagent.transcript.activity ?? String(localized: "Thinking"))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let startedAt = subagent.transcript.startedAt {
                            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                Text(Duration.seconds(max(0, Int(context.date.timeIntervalSince(startedAt)))),
                                     format: .time(pattern: .minuteSecond))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if running.count > Self.visibleRows {
                Text("+\(running.count - Self.visibleRows) more")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 28)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }
}
