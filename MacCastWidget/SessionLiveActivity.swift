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
                    Label(context.state.hostName ?? "Peering", systemImage: symbol(for: context.state.phase))
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
                        Text(statusText(for: context.state.phase))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if context.state.phase != .dropped {
                            Link(destination: URL(string: "peering://disconnect")!) {
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
    /// Where the Restore link goes. The app already handles this: `MacCastApp`'s `onOpenURL`
    /// routes `peering://connect` to `reconnectToLastHost()`.
    static let restoreURL = URL(string: "peering://connect")!

    let context: ActivityViewContext<SessionActivityAttributes>

    private var isActive: Bool { context.state.phase == .active }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: context.state.phase))
                    .font(.title2)
                    .foregroundStyle(.white.opacity(isActive ? 1 : 0.5))
                    .frame(width: 28)

                Text(context.state.hostName ?? "Peering")
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Fixed width so the timer right-aligns to the card edge without
                // reserving space for its maximum possible string length.
                elapsed(context)
                    .frame(width: 88, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text(statusText(for: context.state.phase))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let path = context.state.path {
                    Text(path.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.14), in: Capsule())
                }

                Spacer(minLength: 8)

                if context.state.phase == .dropped {
                    Link(destination: Self.restoreURL) {
                        Label("Restore", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                } else {
                    Link(destination: URL(string: "peering://disconnect")!) {
                        Text("End")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
            }
            .padding(.leading, 38)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 20)
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
    case .dropped: return "wifi.slash"
    }
}

private func statusText(for phase: SessionActivityAttributes.Phase) -> String {
    switch phase {
    case .pending: return "Waiting for the Mac"
    case .active: return "Connected"
    case .reconnecting: return "Reconnecting…"
    case .dropped: return "Connection dropped"
    }
}
