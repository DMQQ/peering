import MacCastKit
import RemoteCore
import SwiftUI

/// The Macs that are open, one tab each, and the `+` that opens another.
///
/// **Drawn only when there is more than one**, which is the whole of what makes the feature
/// invisible to somebody who has one Mac: a strip with a single tab on it is a row of chrome that
/// tells the user nothing they did not already know, and takes a line off the picture to do it.
/// The first Mac is free on every plan, so a free user with one Mac never sees this at all.
/// ``RemoteScreen`` is where that decision is made; this view draws whatever it is handed.
///
/// A tap switches rather than connects. The Mac being left is asked to stop sending its picture
/// and the Mac being arrived at is asked to start, and neither is a disconnect: its shells keep
/// running, its clipboard is still there, and it is still awake. That is the entire difference
/// between this and ending one session to begin another. See ``SessionModel/activateSession(_:)``.
///
/// It draws on the one strip every other screen draws on — see ``TabStrip`` — rather than as the
/// floating capsules it used to be. The session strip was the third copy of a tab and the one
/// that had drifted furthest: no scroller, so four Macs squeezed into the width instead of
/// scrolling, and a tab with no way to end it but the pill's quit-everything button.
struct SessionTabs: View {
    @Environment(SessionModel.self) private var model

    /// Where the screen's chrome regions are collected.
    ///
    /// **Not optional, and it is the one thing about this view that is a correctness requirement
    /// rather than a drawing.** The strip lies over the picture, and the gesture surface is a
    /// UIKit view underneath the SwiftUI chrome: a touch aimed at a tab is delivered to the canvas
    /// as well unless the region is reported. A tab switch that also clicks whatever is at that
    /// point on the Mac is the failure this prevents, and it is silent — the Mac does something
    /// the user did not ask for, a second after they asked for something else.
    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// The Mac the user has asked to end, while the question is up.
    ///
    /// Held here rather than on the container: it is a question about a tap that has just
    /// happened, and the strip is rebuilt on every phase change of every Mac. Same shape as the
    /// terminal strip's `pendingClose`, and for the same reason.
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
        // **The question is asked from the strip rather than from the tab**, exactly as the
        // terminal strip asks it from its own: one alert for the whole row, whose subject is a
        // Mac named in the model. A copy per tab would be one alert per tab, all of them able to
        // be up at once.
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

    /// One Mac, named as the picker names it.
    private func tab(_ session: MacSession, isSelected: Bool) -> some View {
        let name = displayName(session)

        return TabChip(
            isSelected: isSelected,
            onSelect: { model.activateSession(session.id) },
            onClose: { pendingEnd = session },
            closeLabel: String(localized: "End \(name)")
        ) {
            // The dot says what a name cannot: whether this Mac is up right now. Drawn the way
            // the picker draws it — filled for a Mac that is there, hollow for one that is not
            // known to be — and as a third thing for one being reconnected to, which is neither up
            // nor gone and must not be drawn as either.
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

    /// The `+`, which is where the plan is asked for.
    ///
    /// **Drawn as itself whether or not the plan includes it**: a `+` that becomes a padlock is a
    /// control that answers "what does this do" with nothing, and this button is how somebody with
    /// one Mac finds out the app can hold several. See ``PlanLocked``.
    ///
    /// `isIncluded` is passed rather than left to the map because the first Mac is free on every
    /// plan: the question is never "is this paid", it is "is this paid, or is this the first one".
    ///
    /// The 11 points of top padding centre it on the tab names rather than on the tab, which is
    /// the same correction the strips inside the terminal panels make — see ``TabStrip``.
    @ViewBuilder
    private var addButton: some View {
        PlanLocked(
            capability: .concurrentSessions,
            title: String(localized: "Another Mac"),
            diameter: 20,
            isIncluded: model.canAddAnotherSession
        ) {
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
        }
        .padding(.top, 11)
        .padding(.trailing, 8)
    }

    /// What to call a Mac, in the one order that puts a person's own name for it first.
    ///
    /// The user's name if they have given one, then the Mac's own, then a placeholder. A tab
    /// reading six hexadecimal characters would be the device ID standing where a person expects
    /// the name of their machine, which is the mistake ``SessionModel/displayName(forHostID:)``
    /// exists to prevent everywhere else.
    private func displayName(_ session: MacSession) -> String {
        session.hostID.flatMap { model.displayName(forHostID: $0) }
            ?? session.hostName
            ?? String(localized: "A Mac")
    }

    /// What colour a Mac's dot is, which is three answers rather than two.
    private func dotFill(_ session: MacSession) -> Color {
        if session.isReconnecting { return ColorPalette.caution }
        return session.phase == .ready ? .green : .clear
    }
}
