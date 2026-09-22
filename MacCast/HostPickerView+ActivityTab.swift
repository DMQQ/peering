import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

// MARK: - Activity Tab

/// One line in "Recent connections", whichever kind of machine was at the other end.
///
/// A type of this screen's own rather than a protocol over the two records. They answer different
/// questions — a Mac session has a path and a byte count, a shell has an outcome — and the only
/// things this list needs from either are a name, a sentence and a time. Flattening them here
/// keeps that pairing in one place instead of teaching two stored records about a list neither of
/// them is part of.
private enum RecentConnection: Identifiable {
    case mac(ClientSessionRecord)
    case shell(SSHConnectionRecord)

    var id: UUID {
        switch self {
        case .mac(let session): return session.id
        case .shell(let record): return record.id
        }
    }

    var startedAt: Date {
        switch self {
        case .mac(let session): return session.startedAt
        case .shell(let record): return record.startedAt
        }
    }
}

/// One fact about a session: what it is on the left, what it came to on the right.
///
/// A free function rather than a method on either screen, because two screens in this file are made
/// of these — a past session's detail, and the direct path's two rates — and a second copy of a
/// row is where the two start drifting apart. It is the same reasoning the app's shared controls
/// were lifted for, one size down.
private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(label)
            .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(value)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
    }
    .font(.subheadline)
}

struct ActivityTab: View {
    @Environment(SessionModel.self) private var model
    /// Read only for the shells: this tab is where everything that has connected is listed, and a
    /// shell is one of those — see ``recent``.
    @Environment(SSHModel.self) private var servers

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TabScreenHeader(
                            "Sessions",
                            detail: "Recent sessions and relay use."
                        )
                        if model.storeManager.access.showsRelayAllowance {
                            relayCard
                        }
                        // Only once a session has had to leave this network. Until then there is
                        // no figure to draw, and a card whose whole content is "nothing yet" is
                        // the absence of an answer drawn as one.
                        if let summary = model.directPathSummary {
                            directPathCard(summary)
                        }
                        recentConnectionsCard
                    }
                    .adaptiveContentColumn()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Relay card

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Controls.sectionLabel("Relay", systemImage: "network")
            }
            .foregroundStyle(.secondary)

            // The whole allowance becomes the way to buy more of it. This card is where the
            // limit is felt — it is the one place in the app that counts the minutes down — so
            // it is the one place where "and here is how to stop counting" belongs. Paid plans
            // never reach this view because they have no relay allowance to inspect.
            Button(action: openUpgradePaywall) {
                relayMeterDetail
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var relayMeterDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Free relay time")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(relayRemainingLabel)
                    .font(.caption.weight(.medium))
                    // Warms with the bar rather than staying grey. The figure is the one piece of
                    // text on this card that changes on its own, and the moment it stops being
                    // comfortable it should be the thing the eye lands on.
                    .foregroundStyle(relayAllowanceIsLow ? ColorPalette.caution : .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(relayAllowanceIsLow ? ColorPalette.caution : ColorPalette.accent)
                        .frame(
                            width: geo.size.width * (model.relayAllowanceRemainingFraction ?? 0),
                            height: 6
                        )
                        .animation(.easeInOut(duration: 0.6), value: model.relayAllowanceRemainingFraction)
                }
            }
            .frame(height: 6)

            HStack {
                Label(relayBandwidth, systemImage: "arrow.down.circle")
                Spacer()
                // The window the meter is counting in, which is the relay's own: a rolling 24
                // hours rather than a calendar day. It used to say "last 30 days", which was the
                // history limit and never what this number was.
                Text("last 24 hours")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Your allowance is measured in relay time, not a fixed number of sessions. What is shown here is estimated from the sessions recorded on this device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if relayAllowanceIsLow {
                upgradeCallToAction
                    .padding(.top, 2)
            }
        }
    }

    /// The way to buy more of the allowance, drawn only when there is little enough left to say so.
    ///
    /// The card is already a button and already carries a chevron, which is enough for somebody who
    /// came here to read the figure. This is for the moment the figure has become the reason they
    /// came: there, "tap the card" is something the user has to work out, and a filled control they
    /// can simply press is not.
    ///
    /// A label rather than a `Button`, and deliberately — it is *inside* one. The whole card is the
    /// control, so every point of this is already part of a target that was there before it; a real
    /// button nested in a button's label is a second tap target inside the first, and the outer one
    /// is the one that wins.
    private var upgradeCallToAction: some View {
        HStack(spacing: 7) {
            Text("Upgrade to \(recommendedTierName)")
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(ColorPalette.onInk)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(ColorPalette.ink, in: Capsule())
    }

    /// Whether the day's allowance is nearly gone — the only thing the bar says beyond its length.
    ///
    /// One state rather than two, and the threshold is the same constant the app's own offer is
    /// decided on, so the card and the sheet that follows a session agree about what "running low"
    /// means. A bar at zero is the extreme of a bar running out, and two ambers a few degrees apart
    /// — one for nearly, one for gone — is the near-match the palette's own note warns about. The
    /// words distinguish the two; the colour only says to look.
    ///
    /// `nil` is an unmetered plan, which draws no bar at all — the unlimited branch is above.
    private var relayAllowanceIsLow: Bool {
        guard let fraction = model.relayAllowanceRemainingFraction else { return false }
        return fraction <= SessionOfferPolicy.lowRelayAllowanceFraction
    }

    /// Opens the paywall saying the thing that is true of this card right now.
    ///
    /// The two reasons are not interchangeable: one names the figure that is left, the other
    /// describes what the relay is to somebody who has not been told. A card showing "41m left" that
    /// opens a screen never mentioning the 41 minutes is a card that was not reading its own meter —
    /// and the same two reasons are what ``SessionModel`` chooses between when it offers by itself,
    /// so the figure means the same thing whichever way the screen was reached.
    private func openUpgradePaywall() {
        if relayAllowanceIsLow, let remaining = model.relaySecondsRemainingEstimate {
            model.paywallReason = remaining <= 0 ? .quotaExhausted : .runningLow(remaining: remaining)
        } else {
            model.paywallReason = .upgrade
        }
    }

    /// The name on the card's button when there is little enough left to offer more.
    ///
    /// Read off the tier the app recommends rather than typed, because the paywall this opens will
    /// have that tier already chosen — and a button that names one rung of a ladder while the screen
    /// it opens points at another is a promise the next tap breaks.
    private var recommendedTierName: String {
        StoreManager.Tier.allCases.first { $0.isRecommended }?.name ?? "Pro"
    }


    // MARK: Direct path card

    /// How often the picture went around the relay, and what the two ways of getting it cost.
    ///
    /// **The one figure in this tab that the list below it cannot give.** A finished session is
    /// drawn under its connection's path, and a session the relay spliced reads as `Relay` whether
    /// or not the picture went around it, so counting the rows by eye answers a different question
    /// from the one the direct path is judged on.
    ///
    /// Written from what the records hold and nothing else: no sentence here explains *why* a
    /// direct picture costs what it does, because the records do not say. What is counted, and what
    /// is deliberately left out of it, is ``DirectPathSummary``.
    private func directPathCard(_ summary: DirectPathSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Controls.sectionLabel(
                "Direct path",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Picture went around the relay")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(shareLabel(summary.directShare))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                // The count under the share, and not a second percentage. The history is a few
                // dozen sessions at most, so "3 of 12" is the figure and a rounded one above it is
                // only a reading of it — but a reading is what "how often" is asked for, and the
                // count is what it can be checked against.
                Text(shareDetail(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Both rates or neither. One of them on its own is not the comparison this block
                // exists for, and the relay's own bytes are already reported on the card above.
                if let direct = summary.directBytesPerSecond,
                   let relayed = summary.relayedBytesPerSecond {
                    Controls.divider
                    detailRow("Direct picture", bytesPerSecondLabel(direct))
                    detailRow("Relayed picture", bytesPerSecondLabel(relayed))
                }

                // The one thing the records cannot say for themselves, and the reason it is here
                // rather than left in the code: a history from before the app could tell the paths
                // apart reads as a relayed one, and a card showing somebody no direct sessions at
                // all would be contradicting what they watched happen.
                Text("Sessions recorded before the app could tell which way the picture went count as relayed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    // MARK: Recent connections

    private var recentConnectionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Controls.sectionLabel("Recent connections", systemImage: "clock.arrow.circlepath")

            if recent.isEmpty {
                Text("Nothing yet. Pair with a Mac, or add a server in the Servers tab, and what you connect to appears here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { item in
                        recentItemRow(item)
                    }
                }
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Everything that has connected lately, Mac and server alike, newest first.
    ///
    /// One list rather than two cards, because the question the card answers — "what have I been
    /// connected to" — does not change with the kind of machine at the other end. A shell on a VPS
    /// is a connection this phone made in exactly the way a session with a Mac is, and two lists
    /// would make the reader merge them by timestamp themselves.
    private var recent: [RecentConnection] {
        let macs = model.sessionHistory.map(RecentConnection.mac)
        let shells = servers.history.map(RecentConnection.shell)
        return (macs + shells).sorted { $0.startedAt > $1.startedAt }
    }

    @ViewBuilder
    private func recentItemRow(_ item: RecentConnection) -> some View {
        switch item {
        case .mac(let session):
            NavigationLink {
                SessionHistoryDetail(session: session)
            } label: {
                recentRow(
                    symbol: "macbook",
                    name: session.hostName,
                    detail: "\(session.path.rawValue) · \(durationLabel(session.duration)) · \(bytesLabel(session.videoBytesReceived))",
                    startedAt: session.startedAt,
                    // The one of the three that leads somewhere: this is a NavigationLink, so the
                    // chevron is a promise the row keeps.
                    navigates: true
                )
            }
            .buttonStyle(.plain)

        case .shell(let record):
            // Only when the server is still there. A log entry that outlives the machine is the
            // reason the record carries its own copy of the name — but a *tap* on one has nowhere
            // to go, and offering it would be a row that fails by opening a screen for a server
            // that does not exist. Same rule as the Servers list, which draws nothing it cannot
            // open.
            if let host = servers.hosts.first(where: { $0.id == record.hostID }) {
                Button { servers.requestOpen(host) } label: {
                    recentRow(
                        symbol: "server.rack",
                        name: record.name,
                        detail: shellDetail(record),
                        startedAt: record.startedAt
                    )
                }
                .buttonStyle(.plain)
            } else {
                recentRow(
                    symbol: "server.rack",
                    name: record.name,
                    detail: shellDetail(record),
                    startedAt: record.startedAt
                )
            }
        }
    }

    /// What happened, in the order a reader wants it: how it went, then what it cost in time.
    ///
    /// A failure leads with the *reason* instead, because for a connection that never opened the
    /// duration is how long it took to fail — a number nobody has ever wanted — and the sentence
    /// the server produced is the only thing on the row worth reading.
    private func shellDetail(_ record: SSHConnectionRecord) -> String {
        if let reason = record.outcome.reason {
            return "Failed · \(reason)"
        }
        return "\(durationLabel(record.duration)) · Connected"
    }

    /// One line of a session. Not always a row that leads anywhere, which is the whole of why it
    /// takes a parameter for the chevron.
    ///
    /// **This one row is three different things.** A Mac session pushes to its detail; a server
    /// shell is *opened*, which is an action rather than a destination; and a server that has since
    /// been removed does nothing at all and is not even a button. Drawn with a chevron
    /// unconditionally, it promised "there is somewhere further on" on all three, and kept that
    /// promise on one. A chevron is a claim about what a tap does, so it is decided by what the tap
    /// does rather than by which list the row is in.
    private func recentRow(
        symbol: String,
        name: String,
        detail: String,
        startedAt: Date,
        navigates: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(RelativeDateTimeFormatter().localizedString(for: startedAt, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if navigates {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowSurface()
    }

    /// How much relay is left, in the shape ``RelayTime`` decides on.
    ///
    /// The arithmetic moved there when the paywall needed the same sentence: the two screens are
    /// read within seconds of each other — the meter, then the sheet it opens — and a figure spelled
    /// two ways between them is the sort of difference that makes an app look like it is guessing.
    ///
    /// `nil` means the plan is not metered, which this card does not draw a meter for — the
    /// unlimited branch is above. The word is here so the label is total rather than a crash waiting
    /// for a plan change to arrive while the card is on screen.
    private var relayRemainingLabel: String {
        guard let remaining = model.relaySecondsRemainingEstimate else { return "Unlimited" }
        return RelayTime.label(remaining) + " left"
    }

    private var relayBandwidth: String {
        ByteCountFormatter.string(fromByteCount: model.relayVideoBytesThisPeriod, countStyle: .file)
            + " received"
    }

    private func bytesLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A picture's rate, in the unit this screen already prints bytes in.
    private func bytesPerSecondLabel(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// How often the picture avoided the relay, as the card prints it.
    ///
    /// Whole percent. The count behind it is a few dozen sessions, so a decimal would be a figure
    /// nobody asked for, and the count itself is on the line underneath for anyone who wants the
    /// figure rather than the reading.
    private func shareLabel(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    /// The same figure the share above it came from, in sessions, which is the number a reader can
    /// check it against.
    ///
    /// Spelled out rather than counted down, because the history is small enough for the small
    /// numbers to be the ordinary case: a first session that punched leaves "1 of the 1 sessions
    /// that left this network", which is a line telling the reader nobody looked.
    private func shareDetail(_ summary: DirectPathSummary) -> String {
        let offNetwork = summary.sessionsOffNetwork == 1
            ? "1 session"
            : "\(summary.sessionsOffNetwork) sessions"
        return "\(summary.sessionsDirect) of the \(offNetwork) that left this network."
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// One past connection, in full.
///
/// Written as cards on the app's own backdrop rather than as a `List`, which is what it was: a
/// system list brings its own background, its own section headers, its own insets and its own
/// everything, and inside a screen that is all near-black and outlined cards it read as a piece of
/// iOS that had landed on top of the app. The rows here are the same rows the Sessions tab uses
/// for the connection it is in — a label on the left, a value on the right — so a session you had
/// and a session you are having are recognisably the same kind of thing.
private struct SessionHistoryDetail: View {
    let session: ClientSessionRecord

    /// Whether the last copy landed, so the button can say so for a moment.
    ///
    /// The same shape the Settings screen uses for its diagnostics copy, and for the same
    /// reason: a button that gives no feedback after a tap reads as a button that did nothing,
    /// and the only way to check a paste is to go somewhere else and paste it.
    @State private var copied = false

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Controls.card("Connection") {
                        detailRow("Mac", session.hostName)
                        Controls.divider
                        detailRow("Path", session.path.rawValue)
                        Controls.divider
                        detailRow("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Controls.divider
                        detailRow("Duration", durationLabel)
                        // **The second figure, for the sessions where there are two.** A session the
                        // app put back after a drop covers the minutes it was not connected for, and
                        // this is the one screen that can say so: the relay meter counts the other
                        // figure, so without this row a user reading "2h 10m" here and watching
                        // their allowance fall by forty minutes has been told two things and given
                        // nothing to reconcile them with. Shown only when the two differ, which for
                        // a session that was never interrupted they do not.
                        if session.wasInterrupted {
                            Controls.divider
                            detailRow("Connected", connectedLabel)
                        }
                        Controls.divider
                        detailRow(
                            "Video received",
                            ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file)
                        )
                    }

                    Controls.card("Session log") {
                        if session.logs.isEmpty {
                            Text("No diagnostic events were recorded for this session.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.logs.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle(session.hostName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // In the bar rather than in the card, because the card scrolls: a control that
            // belongs to the whole screen should not be somewhere you have to scroll to find,
            // and a session with sixty log lines puts the bottom of the card a long way down.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Copied" : "Copy session log")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// Everything this screen knows, as text, for pasting into a message.
    ///
    /// The rows and the log together rather than the log alone. A line saying which transport
    /// carried the picture means nothing without the session it belongs to, and whoever reads
    /// this is looking at a pasted paragraph with none of the context this screen has around
    /// it. The version is here for the same reason: "the two apps must match" is the first
    /// thing anybody asks about a failure, and it costs one line to answer it in advance.
    private var logText: String {
        var lines = [
            "Peering session · \(session.hostName)",
            "App version: \(ProtocolInfo.version)",
            "Path: \(session.path.rawValue)",
            "Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))",
            "Duration: \(durationLabel)",
        ]
        // The same second row the card draws, and for the same reason: this is what somebody pastes
        // into a message about a session, and a paste that says three hours about a session the
        // meter charged forty minutes for is the confusion the row above exists to remove.
        if session.wasInterrupted { lines.append("Connected: \(connectedLabel)") }
        lines.append("Video received: \(ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file))")
        lines.append("")
        lines += session.logs.isEmpty
            ? ["No diagnostic events were recorded for this session."]
            : session.logs
        return lines.joined(separator: "\n")
    }

    private var durationLabel: String { secondsLabel(session.duration) }

    /// The seconds the session was actually up for, which is the figure the allowance spends.
    private var connectedLabel: String { secondsLabel(session.connectedSeconds) }

    /// A stretch of time as this screen prints one.
    ///
    /// One spelling for both rows, because they sit on top of each other and are the same kind of
    /// figure: two spellings would read as two different measurements rather than as the same one
    /// taken twice.
    private func secondsLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) seconds" : "\(total / 60)m \(total % 60)s"
    }
}
