import ActivityKit
import SwiftUI
import WidgetKit

/// A Peering SSH session on the Lock Screen and in the Dynamic Island.
///
/// Same card as the Mac session's, one symbol apart. See ``ActivityCard`` for why the two are one
/// shape; what differs here is what it says. A shell has no transport to name and no dropped state
/// to come back from, and it can have several of itself open at once, which is the reading that
/// earns the second half of the status line.
struct TerminalLiveActivity: Widget {
    static let endURL = URL(string: "peering://end-shells")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalActivityAttributes.self) { context in
            ActivityCard(
                symbol: "terminal",
                tone: context.state.phase == .live ? .live : .pending,
                name: context.state.serverName,
                status: statusText(for: context.state),
                startedAt: context.state.startedAt,
                action: ActivityCardAction(title: actionTitle(for: context.state), url: Self.endURL)
            )
            .activityBackgroundTint(ActivityCard.backgroundTint)
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
                        Text(statusText(for: context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Link(destination: Self.endURL) {
                            Text(actionTitle(for: context.state))
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

@ViewBuilder
private func terminalElapsed(_ context: ActivityViewContext<TerminalActivityAttributes>) -> some View {
    if let started = context.state.startedAt {
        Text(started, style: .timer)
            .font(.title3.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            // A `.timer` draws its reading at the leading edge of whatever width it is offered,
            // whatever frame it is put in — see ``ActivityCard``.
            .multilineTextAlignment(.trailing)
    }
}

/// The state, with the shell count folded in when there is more than one.
///
/// One shell is the ordinary case and says nothing; three is the fact worth the room, and it is
/// also what the action beside it ends. Last in the sentence for the reason ``ActivityCard`` gives:
/// the state is what must survive a narrow card, and this is what may not.
private func statusText(for state: TerminalActivityAttributes.ContentState) -> String {
    let phase = state.phase == .live ? String(localized: "Connected") : String(localized: "Connecting…")
    return state.shellCount > 1 ? String(localized: "\(phase) · \(state.shellCount) shells") : phase
}

/// Ending one shell is ending this card; ending three is ending the session it stands for, and the
/// button says which one it is about to do.
private func actionTitle(for state: TerminalActivityAttributes.ContentState) -> String {
    state.shellCount > 1 ? String(localized: "End all") : String(localized: "End")
}
