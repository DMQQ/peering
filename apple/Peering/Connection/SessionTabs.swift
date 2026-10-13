import PeeringKit
import RemoteCore
import SwiftUI

/// The Macs that are open, one tab each, and the `+` that opens another.
/// Drawn only when there is more than one: a single-tab strip is chrome telling the user nothing. ``RemoteScreen`` makes that decision.
/// A tap switches rather than connects: the Mac left stops sending its picture but is not disconnected, and its shells keep running. See `activateSession(_:)`.
struct SessionTabs: View {
    @Environment(SessionModel.self) private var model

    /// Not optional, a correctness requirement: the strip lies over the picture and the gesture surface is a UIKit view beneath it, so an unreported region also clicks whatever is at that point on the Mac.
    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// Held here, not on the container: the strip is rebuilt on every phase change of every Mac.
    @State private var pendingEnd: MacSession?

    var body: some View {
        TabStrip(
            items: model.openSessions,
            selection: model.activeSessionID,
            fill: AnyShapeStyle(.ultraThinMaterial)
        ) { session, isSelected in
            tab(session, isSelected: isSelected)
        } accessory: {
            addButton
        }
        .reportChromeFrame(.sessionTabs, into: $chromeFrames)
        // Asked from the strip, not the tab: one alert for the row, not one per tab all able to be up at once.
        .terminalEndPrompt(
            name: pendingEnd.map(displayName) ?? "",
            detail: String(localized: "The connection to it closes. The Mac itself is left alone, and the shells running on it keep running."),
            isPresented: Binding(
                get: { pendingEnd != nil },
                set: { if !$0 { pendingEnd = nil } }
            ),
            onEnd: {
                guard let session = pendingEnd else { return }
                pendingEnd = nil
                model.endSession(session.id)
            }
        )
    }

    private func tab(_ session: MacSession, isSelected: Bool) -> some View {
        let name = displayName(session)

        return TabChip(
            isSelected: isSelected,
            onSelect: { model.activateSession(session.id) },
            onClose: { pendingEnd = session },
            closeLabel: String(localized: "End \(name)")
        ) {
            // The dot is drawn as the picker draws it: filled for up, hollow for not known, and a third form for reconnecting, which is neither up nor gone.
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
        } name: {
            TabName(text: name, isSelected: isSelected, colour: ColorPalette.ink)
        }
        .accessibilityLabel(isSelected ? String(localized: "\(name), showing") : name)
    }

    /// The 11 points of top padding centre it on the tab names, as in the terminal panels' strips.
    @ViewBuilder
    private var addButton: some View {
        Menu {
            ForEach(model.closedPairedMacs, id: \.id) { mac in
                Button(mac.name) { model.addSession(hostID: mac.id) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(ColorPalette.surface, in: Circle())
        }
        .accessibilityLabel("Another Mac")
        .padding(.top, 11)
        .padding(.trailing, 8)
    }

    /// The user's name, then the Mac's own, then a placeholder: never the device ID.
    private func displayName(_ session: MacSession) -> String {
        session.hostID.flatMap { model.displayName(forHostID: $0) }
            ?? session.hostName
            ?? String(localized: "A Mac")
    }

    private func dotFill(_ session: MacSession) -> Color {
        if session.isReconnecting { return ColorPalette.caution }
        return session.phase == .ready ? .green : .clear
    }
}
