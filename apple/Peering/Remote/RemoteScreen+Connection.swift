import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    /// A Mac being put back is neither green nor red: the frames stopping is why the retry exists.
    /// Read from the session, not `isResuming`: that flag clears on the first phase holding a session, which a dial is.
    var isReconnectingToMac: Bool { model.isBeingPutBack }

    /// Only the poor band speaks: "Slow" at 40 ms and up would be on screen for most relayed sessions, and a word that is always there is not a warning.
    var slowConnectionLabel: String? {
        guard model.phase == .ready, model.isVideoStreaming, let latency = model.latencyMilliseconds,
              LatencyQuality.of(milliseconds: latency) == .poor else { return nil }
        return LatencyQuality.poor.pillLabel
    }

    /// Amber is the palette's caution: a reconnection is not a failure.
    var connectionDotTint: Color {
        if isReconnectingToMac || slowConnectionLabel != nil { return ColorPalette.caution }
        return model.isVideoStreaming ? .green : .red
    }

    var connectionDotLabel: String {
        if isReconnectingToMac { return model.hostPlatform.adapt(String(localized: "Reconnecting to the Mac")) }
        if slowConnectionLabel != nil { return LatencyQuality.poor.spokenLabel }
        return model.isVideoStreaming ? String(localized: "Connected") : String(localized: "Not streaming")
    }

    var connectionPathChip: some View {
        Text(connectionPathTitle)
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .pillChip()
            .accessibilityLabel("Connection path, \(connectionPathTitle)")
    }

    /// The second fact appears only when different: on a LAN the picture already goes direct.
    /// Read from `usedDirectPath`, not the path above: a punched session still has its control connection relayed (and metered), only the picture went around.
    private var connectionPathTitle: String {
        let connection = model.connectionPath?.rawValue ?? "None"
        guard model.usedDirectPath, model.connectionPath == .relay else { return connection }
        return "\(connection)·P2P"
    }
}
