import ActivityKit
import SwiftUI
import WidgetKit

/// A Peering session on the Lock Screen and in the Dynamic Island.
///
/// The reason this is worth having over a notification is the clock: the duration is rendered by
/// the system from `startedAt`, so it stays correct on a screen where none of this app is
/// running, and it costs no updates to keep ticking.
struct SessionLiveActivity: Widget {
    /// Where the Restore link goes. The app already handles this: `MacCastApp`'s `onOpenURL`
    /// routes `peering://connect` to `reconnectToLastHost()`.
    nonisolated static let restoreURL = URL(string: "peering://connect")!
    nonisolated static let endURL = URL(string: "peering://disconnect")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            ActivityCard(
                symbol: "macbook",
                tone: tone(for: context.state.phase),
                name: context.state.hostName ?? String(localized: "Mac"),
                status: statusText(for: context.state),
                startedAt: context.state.startedAt,
                action: action(for: context.state.phase)
            )
            .activityBackgroundTint(ActivityCard.backgroundTint)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Both regions claim the full width and align inside it. A region otherwise sizes
                // to its own content, which puts the timer wherever the Mac's name happens to end
                // — mid-card — instead of against the trailing edge, where every other Live
                // Activity and the Lock Screen card below both put it.
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.hostName ?? String(localized: "Mac"), systemImage: symbol(for: context.state.phase))
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
                // The compact slot is a few characters wide beside the housing. The system's
                // timer collapses to minutes for exactly this reason; anything longer is
                // truncated by the island rather than by us, which reads as a bug.
                elapsed(context)
                    .frame(maxWidth: 46)
            } minimal: {
                // One glyph and nothing else. Here, and only here, the glyph is the state rather
                // than the kind of thing: the island has no room for a dot or for a word, so this
                // is the one place a dropped session can look different from a live one.
                Image(systemName: symbol(for: context.state.phase))
            }
            // Monochrome, like the app. The default keyline is the widget's accent colour, and
            // a tinted outline around a session that is only ever black and white is the one
            // piece of chrome on the Lock Screen that would look like a different app made it.
            .keylineTint(.white)
        }
    }
}

/// The elapsed duration, or nothing at all before the session is up.
///
/// Deliberately not "0:00" while pending: a clock that has started says something that is not
/// true yet, and the pending state is exactly when the user is deciding whether to walk away.
@ViewBuilder
private func elapsed(_ context: ActivityViewContext<SessionActivityAttributes>) -> some View {
    if let started = context.state.startedAt {
        Text(started, style: .timer)
            .font(.title3.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            // A `.timer` fills the width it is offered and draws its reading at the leading edge,
            // whatever frame it is put in — see ``ActivityCard``. In the regions above, which are
            // trailing-aligned and full width, that is the clock sitting at the far left of them.
            .multilineTextAlignment(.trailing)
    }
}

/// The state in words, with the transport and the count folded into the sentence.
///
/// The path used to be a chip beside the word "Connected", which said one thing twice. The app's
/// own rows settled this shape long before the card did: a Mac that is connected is "Connected via
/// LAN", and a row's second line carries two facts as "one · the other".
///
/// The count is the part that has never been drawn anywhere. The state has carried it from the
/// beginning (`SessionModel` passes the number of open sessions on every phase change) and no view
/// on either surface has ever shown it, so a phone holding two Macs has been describing one of
/// them. It goes last, because it is the fact that may be cut short.
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

/// What the card offers: the way back in when the session was lost, and the way out otherwise.
///
/// A dropped card has no End, because there is nothing left to end: the Mac is already gone
/// as far as this phone is concerned, and the only thing worth doing at that moment is offering
/// the session back.
private func action(for phase: SessionActivityAttributes.Phase) -> ActivityCardAction {
    phase == .dropped
        ? ActivityCardAction(title: String(localized: "Restore"), url: SessionLiveActivity.restoreURL)
        : ActivityCardAction(title: String(localized: "End"), url: SessionLiveActivity.endURL)
}

/// The phase, as a glyph. The island's mark rather than the card's, which has a tile and a dot to
/// say it with and words under it.
private func symbol(for phase: SessionActivityAttributes.Phase) -> String {
    switch phase {
    case .pending: return "hourglass"
    case .active: return "display"
    case .reconnecting: return "arrow.clockwise"
    case .dropped: return "wifi.slash"
    }
}
