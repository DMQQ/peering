import MacCastKit
import RemoteCore
import SwiftUI

/// The Macs that are open, one tab each, and the `+` that opens another.
///
/// **Drawn only when there is more than one**, which is the whole of what makes the feature
/// invisible to somebody who has one Mac: a strip with a single tab on it is a row of chrome that
/// tells the user nothing they did not already know, and takes a line off the picture to do it.
/// The first Mac is free on every plan, so a free user with one Mac never sees this at all.
///
/// A tap switches rather than connects. The Mac being left is asked to stop sending its picture
/// and the Mac being arrived at is asked to start, and neither is a disconnect: its shells keep
/// running, its clipboard is still there, and it is still awake. That is the entire difference
/// between this and ending one session to begin another. See ``SessionModel/activateSession(_:)``.
struct SessionTabs: View {
    @Environment(SessionModel.self) private var model

    /// How tall a tab is, and the size the `+` is drawn at to match it.
    ///
    /// Small, because this sits under the status pill rather than beside it: it is chrome about
    /// the session, and the pill is chrome about the connection the user is actually watching.
    private static let tabHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.openSessions, id: \.id) { session in
                tab(session)
            }
            addButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    /// One Mac, named as the picker names it.
    ///
    /// The name is the user's own if they have given one, then the Mac's own, then a placeholder.
    /// A tab reading six hexadecimal characters would be the device ID standing where a person
    /// expects the name of their machine, which is the mistake ``SessionModel/displayName(forHostID:)``
    /// exists to prevent everywhere else.
    private func tab(_ session: MacSession) -> some View {
        let isActive = session.id == model.activeSessionID
        let name = session.hostID.flatMap { model.displayName(forHostID: $0) }
            ?? session.hostName
            ?? "A Mac"

        return Button {
            model.activateSession(session.id)
        } label: {
            HStack(spacing: 5) {
                // The dot says what a name cannot: whether this Mac is up right now. Drawn the
                // way the picker draws it — filled for a Mac that is there, hollow for one that
                // is not known to be — and as a third thing for one being reconnected to, which
                // is neither up nor gone and must not be drawn as either.
                Circle()
                    .fill(dotFill(session))
                    .overlay(
                        Circle().strokeBorder(
                            session.isReconnecting || session.phase == .ready
                                ? .clear : Color.white.opacity(0.35),
                            lineWidth: 1
                        )
                    )
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: Self.tabHeight)
            .background(
                isActive ? ColorPalette.accent.opacity(0.35) : ColorPalette.surface,
                in: Capsule()
            )
            .foregroundStyle(ColorPalette.ink)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)\(isActive ? ", showing" : "")")
    }

    /// The `+`, which is where the plan is asked for.
    ///
    /// **Drawn as itself whether or not the plan includes it**: a `+` that becomes a padlock is a
    /// control that answers "what does this do" with nothing, and this button is how somebody with
    /// one Mac finds out the app can hold several. See ``PlanLocked``.
    ///
    /// `isIncluded` is passed rather than left to the map because the first Mac is free on every
    /// plan: the question is never "is this paid", it is "is this paid, or is this the first one".
    @ViewBuilder
    private var addButton: some View {
        PlanLocked(
            capability: .concurrentSessions,
            title: "Another Mac",
            diameter: Self.tabHeight,
            isIncluded: model.canAddAnotherSession
        ) {
            Menu {
                ForEach(model.closedPairedMacs, id: \.id) { mac in
                    Button(mac.name) { model.addSession(hostID: mac.id) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: Self.tabHeight, height: Self.tabHeight)
                    .background(ColorPalette.surface, in: Circle())
            }
            .accessibilityLabel("Another Mac")
        }
    }

    /// What colour a Mac's dot is, which is three answers rather than two.
    private func dotFill(_ session: MacSession) -> Color {
        if session.isReconnecting { return ColorPalette.caution }
        return session.phase == .ready ? .green : .clear
    }
}
