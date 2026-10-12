import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

// MARK: - Activity Tab

/// A type of this screen's own, not a protocol over the two records: a Mac session and a shell answer different questions and the list needs only a name, a sentence and a time.
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
    @Environment(SSHModel.self) private var servers

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TabScreenHeader(
                            String(localized: "Sessions"),
                            detail: String(localized: "Recent sessions and relay use.")
                        )
                        if model.storeManager.access.showsRelayAllowance {
                            relayCard
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
                Controls.sectionLabel(String(localized: "Relay"), systemImage: "network")
            }
            .foregroundStyle(.secondary)

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
                // The relay's rolling 24 hours, not a calendar day or the 30-day history limit.
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

    /// A label rather than a Button: it sits inside the card's button, and a nested button's outer target wins.
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

    /// One near-out state rather than two ambers: the words distinguish nearly from gone and the colour only says to look. The threshold is the constant the app's offer uses. `nil` is an unmetered plan.
    private var relayAllowanceIsLow: Bool {
        guard let fraction = model.relayAllowanceRemainingFraction else { return false }
        return fraction <= SessionOfferPolicy.lowRelayAllowanceFraction
    }

    /// Two paywall reasons, the same two ``SessionModel`` picks between: one names the minutes left, the other explains the relay.
    private func openUpgradePaywall() {
        if relayAllowanceIsLow, let remaining = model.relaySecondsRemainingEstimate {
            switch SessionOfferPolicy.lowAllowanceReason(
                estimate: remaining,
                report: model.relayRemainingSecondsFromRelay,
                now: Date()
            ) {
            case .quotaExhausted: model.paywallReason = .quotaExhausted
            case .runningLow(let left): model.paywallReason = .runningLow(remaining: left)
            case .firstSession: model.paywallReason = .upgrade
            }
        } else {
            model.paywallReason = .upgrade
        }
    }

    /// Read off the recommended tier so the button names the rung the paywall opens on.
    private var recommendedTierName: String {
        StoreManager.Tier.pro.name
    }


    // MARK: Recent connections

    private var recentConnectionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Controls.sectionLabel(String(localized: "Recent connections"), systemImage: "clock.arrow.circlepath")

            if recent.isEmpty {
                Text("Nothing yet. Pair with a Mac, or add a server in the Servers tab, and what you connect to appears here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                if !model.sessionHistory.isEmpty {
                    recentSessionSummary
                    Controls.divider
                }
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

    /// Totals over the bounded remote-desktop history, not lifetime usage. Shell connections do
    /// not carry a video-byte count, so they stay in the list below and out of these three figures.
    private var recentSessionSummary: some View {
        let summary = model.recentSessionSummary
        return HStack(spacing: 0) {
            recentSummaryValue(String(localized: "Sessions"), "\(summary.sessionCount)")
            recentSummaryValue(String(localized: "Connected"), RelayTime.label(summary.connectedSeconds))
            recentSummaryValue(String(localized: "Video"), bytesLabel(summary.videoBytes))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(localized: "Latest \(summary.sessionCount) Mac sessions, ")
            + String(localized: "\(RelayTime.label(summary.connectedSeconds)) connected, ")
            + String(localized: "\(bytesLabel(summary.videoBytes)) video received")
        )
    }

    private func recentSummaryValue(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var recent: [RecentConnection] {
        let macs = model.sessionHistory.map(RecentConnection.mac)
        let shells = servers.history.map(RecentConnection.shell)
        return Array((macs + shells).sorted { $0.startedAt > $1.startedAt }.prefix(20))
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
                    name: model.shownName(hostID: session.hostID, fallback: session.hostName),
                    detail: "\(session.path.name) · \(durationLabel(session.duration)) · \(bytesLabel(session.videoBytesReceived))",
                    startedAt: session.startedAt,
                    navigates: true
                )
            }
            .buttonStyle(.plain)

        case .shell(let record):
            // Only when the server still exists: a log entry outlives its machine, but a tap on one has nowhere to go.
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

    /// A failure leads with the reason: for a connection that never opened the duration is just time to fail.
    private func shellDetail(_ record: SSHConnectionRecord) -> String {
        if let reason = record.outcome.reason {
            return String(localized: "Failed · \(reason)")
        }
        return String(localized: "\(durationLabel(record.duration)) · Connected")
    }

    /// The chevron is a parameter because this row is three things: a Mac session pushes to its detail, a server shell is opened (an action), and a removed server does nothing. A chevron claims what a tap does.
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

    /// The arithmetic lives in ``RelayTime``, shared with the paywall so both screens spell the figure the same way. `nil` is an unmetered plan.
    private var relayRemainingLabel: String {
        guard let remaining = model.relaySecondsRemainingEstimate else { return String(localized: "Unlimited") }
        return RelayTime.label(remaining) + " left"
    }

    private var relayBandwidth: String {
        String(localized: "\(ByteCountFormatter.string(fromByteCount: model.relayVideoBytesThisPeriod, countStyle: .file)) received")
    }

    private func bytesLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        spokenSeconds(duration)
    }
}

/// Cards on the app's backdrop rather than a `List`, whose own background, headers and insets read as stray iOS inside a near-black screen.
private struct SessionHistoryDetail: View {
    let session: ClientSessionRecord

    @Environment(SessionModel.self) private var model

    @State private var copied = false

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Controls.card(String(localized: "Connection")) {
                        detailRow(String(localized: "Mac"), model.shownName(hostID: session.hostID, fallback: session.hostName))
                        Controls.divider
                        detailRow(String(localized: "Path"), session.path.name)
                        Controls.divider
                        detailRow(String(localized: "Started"), session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Controls.divider
                        detailRow(String(localized: "Duration"), durationLabel)
                        // The second figure, for sessions put back after a drop: the relay meter counts connected time, so without this row the duration and the allowance spent would disagree. Shown only when the two differ.
                        if session.wasInterrupted {
                            Controls.divider
                            detailRow(String(localized: "Connected"), connectedLabel)
                        }
                        Controls.divider
                        detailRow(
                            String(localized: "Video received"),
                            ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file)
                        )
                    }

                    Controls.card(String(localized: "Session log")) {
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
        .navigationTitle(model.shownName(hostID: session.hostID, fallback: session.hostName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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

    /// The rows and the log together: a transport line means nothing without its session, and the version answers the first question asked about a failure.
    private var logText: String {
        var lines = [
            String(localized: "Peering session · \(model.shownName(hostID: session.hostID, fallback: session.hostName))"),
            String(localized: "App version: \(ProtocolInfo.version)"),
            String(localized: "Path: \(session.path.rawValue)"),
            String(localized: "Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"),
            String(localized: "Duration: \(durationLabel)"),
        ]
        if session.wasInterrupted { lines.append(String(localized: "Connected: \(connectedLabel)")) }
        lines.append(String(localized: "Video received: \(ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file))"))
        lines.append("")
        lines += session.logs.isEmpty
            ? [String(localized: "No diagnostic events were recorded for this session.")]
            : session.logs
        return lines.joined(separator: "\n")
    }

    private var durationLabel: String { secondsLabel(session.duration) }

    private var connectedLabel: String { secondsLabel(session.connectedSeconds) }

    private func secondsLabel(_ seconds: TimeInterval) -> String {
        spokenSeconds(seconds)
    }
}

private func spokenSeconds(_ seconds: TimeInterval) -> String {
    Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
}
