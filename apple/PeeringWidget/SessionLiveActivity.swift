import ActivityKit
import SwiftUI
import WidgetKit

/// A Peering session on the Lock Screen and in the Dynamic Island. The system renders the duration from `startedAt`, so the clock stays correct while the app is not running.
struct SessionLiveActivity: Widget {
    /// Where the Restore link goes: `peering://connect`, routed by `MacCastApp`'s `onOpenURL`.
    nonisolated static let restoreURL = URL(string: "peering://connect")!
    nonisolated static let endURL = URL(string: "peering://disconnect")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            ActivityCard(
                symbol: "macbook",
                tone: tone(for: context.state.phase),
                name: context.state.shownHostName,
                status: statusText(for: context.state),
                startedAt: context.state.startedAt,
                action: action(for: context.state.phase),
                work: context.state.work ?? []
            )
            .activityBackgroundTint(ActivityCard.backgroundTint)
            .activitySystemActionForegroundColor(.white)
            // A dropped card is the way back in anywhere on it, not only on its Restore button.
            .widgetURL(context.state.phase == .dropped ? Self.restoreURL : nil)
        } dynamicIsland: { context in
            DynamicIsland {
                // Both regions claim the full width and align inside it; otherwise the timer sits wherever the Mac's name ends.
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.shownHostName, systemImage: symbol(for: context.state.phase))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    elapsed(context)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(statusText(for: context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if context.state.phase != .dropped {
                            Link(destination: Self.endURL) {
                                Text("End")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: symbol(for: context.state.phase))
            } compactTrailing: {
                // The compact slot is a few characters wide; the system's timer collapses to minutes for that reason.
                elapsed(context)
                    .frame(maxWidth: 46)
            } minimal: {
                // One glyph: here the glyph is the state, as the island has no room for a dot or a word.
                Image(systemName: symbol(for: context.state.phase))
            }
            // Monochrome: the default keyline is the accent colour, which would look foreign.
            .keylineTint(.white)
        }
    }
}

/// The elapsed duration, or nothing before the session is up (a started clock would say something untrue).
@ViewBuilder
private func elapsed(_ context: ActivityViewContext<SessionActivityAttributes>) -> some View {
    if let started = context.state.startedAt {
        Text(started, style: .timer)
            .font(.title3.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            // A `.timer` draws at the leading edge whatever its frame, see ``ActivityCard``.
            .multilineTextAlignment(.trailing)
    }
}

/// The state in words, with the transport and the count folded into the sentence; the count goes last because it may be cut short.
private func statusText(for state: SessionActivityAttributes.ContentState) -> String {
    let phase: String
    switch state.phase {
    case .pending: phase = String(localized: "Waiting for the Mac")
    case .active:
        switch state.path {
        case .lan: phase = String(localized: "Connected via LAN")
        case .relay: phase = String(localized: "Connected via Relay")
        case .direct: phase = String(localized: "Connected directly")
        case nil: phase = String(localized: "Connected")
        }
    case .reconnecting:
        switch state.path {
        case .lan: phase = String(localized: "Reconnecting via LAN…")
        case .relay: phase = String(localized: "Reconnecting via Relay…")
        case .direct: phase = String(localized: "Reconnecting directly…")
        case nil: phase = String(localized: "Reconnecting…")
        }
    case .dropped: phase = String(localized: "Connection dropped")
    }
    guard let count = state.sessionCount, count > 1 else { return phase }
    return String(localized: "\(phase) · \(count) Macs")
}

private func tone(for phase: SessionActivityAttributes.Phase) -> ActivityTone {
    switch phase {
    case .pending, .reconnecting: return .pending
    case .active: return .live
    case .dropped: return .lost
    }
}

/// The way back in when the session was lost, otherwise the way out; a dropped card has no End.
private func action(for phase: SessionActivityAttributes.Phase) -> ActivityCardAction {
    phase == .dropped
        ? ActivityCardAction(title: String(localized: "Restore"), url: SessionLiveActivity.restoreURL)
        : ActivityCardAction(title: String(localized: "End"), url: SessionLiveActivity.endURL)
}

/// The phase as a glyph, the island's mark.
private func symbol(for phase: SessionActivityAttributes.Phase) -> String {
    switch phase {
    case .pending: return "hourglass"
    case .active: return "display"
    case .reconnecting: return "arrow.clockwise"
    case .dropped: return "wifi.slash"
    }
}
