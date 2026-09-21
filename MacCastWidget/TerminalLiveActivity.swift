import ActivityKit
import SwiftUI
import WidgetKit

/// A Peering SSH session on the Lock Screen and in the Dynamic Island.
struct TerminalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalActivityAttributes.self) { context in
            LockScreenTerminal(context: context)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.serverName, systemImage: "terminal")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    terminalElapsed(context)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(terminalStatusText(for: context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Link(destination: URL(string: "peering://end-shells")!) {
                            Text(context.state.shellCount > 1 ? "End all" : "End")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.15), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: "terminal")
            } compactTrailing: {
                terminalElapsed(context)
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "terminal")
            }
            .keylineTint(.white)
        }
    }
}

private struct LockScreenTerminal: View {
    static let endURL = URL(string: "peering://end-shells")!

    let context: ActivityViewContext<TerminalActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.white.opacity(context.state.phase == .live ? 1 : 0.5))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.serverName)
                    .font(.headline)
                    .lineLimit(1)

                Text(terminalStatusText(for: context.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                terminalElapsed(context)
                    .frame(maxWidth: 92, alignment: .trailing)

                Link(destination: Self.endURL) {
                    Text(context.state.shellCount > 1 ? "End all" : "End")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 14)
    }
}

@ViewBuilder
private func terminalElapsed(_ context: ActivityViewContext<TerminalActivityAttributes>) -> some View {
    if let started = context.state.startedAt {
        Text(started, style: .timer)
            .font(.title3.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
    }
}

private func terminalStatusText(for state: TerminalActivityAttributes.ContentState) -> String {
    switch state.phase {
    case .connecting:
        return "Connecting…"
    case .live:
        return state.shellCount > 1 ? "\(state.shellCount) shells open" : "Connected"
    }
}
