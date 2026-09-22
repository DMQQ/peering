import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

/// What this app is costing the Mac it is running on.
///
/// The one panel in this window about the host rather than about the session, and it is here
/// because the question it answers is asked while a session is running: a mosaic of windows is
/// the heaviest thing this app does, and it is exactly the moment somebody watching six capture
/// streams go by wonders whether that is normal. A figure from the app itself beats a figure
/// from Activity Monitor, where the process has to be found among every other one on the Mac
/// before it can be read.
///
/// An extension on the window rather than a type of its own: the state is the window's, and the
/// window is easier to read in pieces than as one file of fifteen hundred lines.
extension HostStatusView {
    var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Resources", detail: "This app's own use, not the Mac's.")

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    cpuTile
                    tileRule
                    memoryTile
                    tileRule
                    networkTile
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().overlay(HostPalette.hairline)

                Text(resourcesNote)
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
                    // The sentence is the point of the panel rather than a caption to it, so it
                    // wraps to as many lines as it needs instead of being clipped to the height
                    // of one.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .hostPanel()
        }
        // Sampled only while this card is on screen, which is the same discipline the preview
        // keeps. Two mach traps and a window invalidation every two seconds is nothing next to
        // an encoder, and it is still work nobody asked for while the window is showing a
        // different section, and the section is what decides whether anyone can read it.
        .task {
            // The baseline is dropped rather than reused, because the interval since the last
            // time this card was on screen is an interval of unknown length: folding it into
            // the first figure would make that figure an average over a period the reader has
            // no way to know.
            sampler.reset()
            while !Task.isCancelled {
                sampler.sample(bytesSent: model.streamedBytes ?? 0)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - The three readings

    private var cpuTile: some View {
        let rates = sampler.rates
        return resourceTile(
            "CPU",
            value: rates.map(HostResourceSampler.cpuPercent) ?? Self.waiting,
            // Both scales, because they are the two ways the same figure gets read and they
            // disagree by the core count: a share of this Mac is what the panel is asking about,
            // and a share of one core is what Activity Monitor's own column shows, so a user who
            // goes to check finds the same number in one of the two.
            caption: rates.map { "of this Mac · \(HostResourceSampler.percent($0.cpuOfOneCore)) of one core" }
                ?? "measuring"
        )
    }

    private var memoryTile: some View {
        resourceTile(
            "Memory",
            // Against the Mac's own memory rather than a bare figure, because "512 MB" answers
            // nothing on its own and "512 MB of 16 GB" answers the question that was asked.
            value: sampler.memoryBytes > 0
                ? HostResourceSampler.memoryText(sampler.memoryBytes)
                : Self.waiting,
            caption: "in use, of \(Self.physicalMemoryText)"
        )
    }

    private var networkTile: some View {
        let rates = sampler.rates
        return resourceTile(
            "Network",
            value: rates.map { HostResourceSampler.networkText($0.bytesPerSecond) } ?? Self.waiting,
            // "Sent" rather than "used": this is the streamer's own count of what it handed
            // over, taken where the bytes leave, so it is measured rather than inferred from the
            // machine's own interface counters.
            caption: "sent from this Mac"
        )
    }

    /// Shapes one reading. The three are the same shape at three scales for the same reason the
    /// icon tiles are: three readings that happen to look similar drift apart at the first
    /// change, and a row of numbers that do not line up reads as a mistake nobody can name.
    private func resourceTile(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(HostPalette.muted)
            Text(value)
                // Monospaced digits rather than a monospaced face: the figures change every two
                // seconds, and proportional digits make the number jump a point sideways each
                // time a 1 arrives, and in a row of three that is the whole row twitching.
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(HostPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(HostPalette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Equal thirds, so the row fills the card at every window width rather than leaving the
        // three readings bunched at the left of a window twice their width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A hairline between two readings, at the height of the tallest of them.
    ///
    /// Filling rather than a fixed few points, because the tiles do not have a height: the
    /// caption under the CPU figure wraps to two lines at the window's minimum width and to one
    /// at its ideal, and a rule of fixed length would then end in the middle of the value row at
    /// one size and short of it at the other.
    private var tileRule: some View {
        Rectangle()
            .fill(HostPalette.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
    }

    // MARK: - What the numbers mean

    /// The sentence under the readings: what is being measured, and what is doing it.
    ///
    /// The first half is the panel's whole claim, and it has to be said rather than implied,
    /// because every other CPU figure a person has seen is about the machine. The second half
    /// names the mosaic where there is one: it is the heaviest thing this app does, and it is
    /// what somebody watching six streams go by would otherwise blame on the app being heavy at
    /// everything. Written without the tile count, because the hero panel above already says
    /// how many windows are on the canvas and "each of its 1 tiles" is the sort of sentence a
    /// count in two places produces.
    var resourcesNote: String {
        let scope = "Measured in this process rather than in the Mac, so nothing else you are running is counted."

        guard let source = model.capturingSource else {
            return "\(scope) Nothing is being captured, so nearly all of this is the window you are looking at."
        }
        if case .mosaic = source {
            return "\(scope) A mosaic is the heaviest thing Peering does: every tile in it is a capture stream of its own."
        }
        return "\(scope) The capture stream and the encoder are most of it."
    }

    /// What a reading shows before there is one. Not a zero: a zero is a claim, and for the
    /// first two seconds of a card's life nobody has measured anything at all.
    private static let waiting = "…"

    private static var physicalMemoryText: String {
        ProcessInfo.processInfo.physicalMemory.formatted(.byteCount(style: .memory))
    }
}
