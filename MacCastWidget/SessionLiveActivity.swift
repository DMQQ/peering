import ActivityKit
import SwiftUI
import WidgetKit

/// A Peering session on the Lock Screen and in the Dynamic Island.
///
/// The reason this is worth having over a notification is the clock: the duration is rendered by
/// the system from `startedAt`, so it stays correct on a screen where none of this app is
/// running, and it costs no updates to keep ticking.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenSession(context: context)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Both regions claim the full width and align inside it. A region otherwise sizes
                // to its own content, which puts the timer wherever the Mac's name happens to end
                // — mid-card — instead of against the trailing edge, where every other Live
                // Activity and the Lock Screen card below both put it.
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.hostName, systemImage: symbol(for: context.state.phase))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    elapsed(context)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(statusText(for: context.state.phase))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                // One glyph and nothing else — the minimal slot clips anything wider.
                Image(systemName: symbol(for: context.state.phase))
            }
            // Monochrome, like the app. The default keyline is the widget's accent colour, and
            // a tinted outline around a session that is only ever black and white is the one
            // piece of chrome on the Lock Screen that would look like a different app made it.
            .keylineTint(.white)
        }
    }
}

/// The Lock Screen presentation: who, what, and for how long.
private struct LockScreenSession: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    private var isActive: Bool { context.state.phase == .active }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: context.state.phase))
                .font(.title3)
                .foregroundStyle(.white.opacity(isActive ? 1 : 0.5))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.hostName)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText(for: context.state.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // The timer belongs against the trailing edge, where every other Live Activity puts
            // it. Beside the name it floats in the middle of the card and reads as a stray
            // number rather than as the thing the card exists to show.
            Spacer(minLength: 12)

            elapsed(context)
                // Bounded, because a live timer cannot be measured: it renders "0:38" now and
                // "12:34:56" an hour from now, so the layout has no content to size against and
                // reserves far more than either. That reserve came out of the name, which
                // truncated a third of the way across the card with the room it had lost still
                // sitting empty beside it — the name is what the card is about, and it was the
                // one thing being shortened.
                //
                // Wide enough for the longest timer the format produces, and trailing-aligned
                // so the digits do not shift as they change. The compact Dynamic Island slot
                // below has always done this; the card was simply missed.
                .frame(maxWidth: 92, alignment: .trailing)
        }
        // Stated rather than left to the stack. An `HStack` with a `Spacer` fills what it is
        // offered, which is not the same as asking for the card: without this the row sizes to
        // its content and the timer sits wherever the name happens to end, well short of the
        // trailing edge, with the rest of the card empty beside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Asymmetric, and deliberately. The system insets a Live Activity's content already;
        // matching that inset on both sides left a margin on the right that reads as the timer
        // having drifted rather than as padding, because the timer is the one thing here that
        // is a column against the edge.
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 14)
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
    }
}

private func symbol(for phase: SessionActivityAttributes.Phase) -> String {
    switch phase {
    case .pending: return "hourglass"
    case .active: return "display"
    case .reconnecting: return "arrow.clockwise"
    }
}

private func statusText(for phase: SessionActivityAttributes.Phase) -> String {
    switch phase {
    case .pending: return "Waiting for the Mac"
    case .active: return "Connected"
    case .reconnecting: return "Reconnecting…"
    }
}
