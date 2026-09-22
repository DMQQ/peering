import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI

extension SessionModel {

    // MARK: - The active session's state

    // **Forwarders, and deliberately all of them.** Every property below is a per-Mac fact that
    // now lives on ``MacSession``: the getter reads it off the session the app is showing, and the
    // setter writes it there. They exist so that no screen had to change when the state underneath
    // it moved, which is the acceptance test for this stage — the seam is proved by being
    // invisible. Stage 5 is what removes the ones whose screens have learned to ask a particular
    // session rather than "the" session.
    //
    // The doc comments that were on these properties are on the stored ones in ``MacSession``.

    /// What the Mac calls itself, or what it was dialled as before the handshake.
    var hostName: String? {
        get { activeSession?.hostName }
        set { activeSession?.hostName = newValue }
    }

    /// The Mac's own device ID, once the handshake has said what it is.
    var currentHostID: String? {
        get { activeSession?.hostID }
        set { activeSession?.hostID = newValue }
    }

    /// Round trip of the control channel, which goes through the relay in every session.
    var latencyMilliseconds: Double? {
        get { activeSession?.latencyMilliseconds }
        set { activeSession?.latencyMilliseconds = newValue }
    }

    /// Round trip of the lane the picture is arriving on, and whether that lane is the direct one.
    var pathLatencyMilliseconds: Double? {
        get { activeSession?.pathLatencyMilliseconds }
        set { activeSession?.pathLatencyMilliseconds = newValue }
    }
    var pathLatencyIsDirect: Bool {
        get { activeSession?.pathLatencyIsDirect ?? false }
        set { activeSession?.pathLatencyIsDirect = newValue }
    }

    /// The one number the status chip shows.
    var shownLatency: Double? { activeSession?.shownLatency }

    var catalog: CaptureCatalog? {
        get { activeSession?.catalog }
        set { activeSession?.catalog = newValue }
    }

    /// This session's notes, newest last. See ``MacSession/notes``.
    var notes: [String] {
        get { activeSession?.notes ?? [] }
        set { activeSession?.notes = newValue }
    }

    var activeSessionHistoryID: UUID? {
        get { activeSession?.activeSessionHistoryID }
        set { activeSession?.activeSessionHistoryID = newValue }
    }
    var activeSessionHistoryStartedAt: Date? {
        get { activeSession?.activeSessionHistoryStartedAt }
        set { activeSession?.activeSessionHistoryStartedAt = newValue }
    }
    var activeSessionBytes: Int64 {
        get { activeSession?.activeSessionBytes ?? 0 }
        set { activeSession?.activeSessionBytes = newValue }
    }
    var lastBandwidthSampleBytes: Int64 {
        get { activeSession?.lastBandwidthSampleBytes ?? 0 }
        set { activeSession?.lastBandwidthSampleBytes = newValue }
    }
    var activeSessionLogs: [String] {
        get { activeSession?.activeSessionLogs ?? [] }
        set { activeSession?.activeSessionLogs = newValue }
    }

    var videoStatus: String {
        get { activeSession?.videoStatus ?? "No video stream" }
        set { activeSession?.videoStatus = newValue }
    }
    /// The frames per second arriving, as measured by the last two polls.
    var videoFramesPerSecond: Double {
        get { activeSession?.videoFramesPerSecond ?? 0 }
        set { activeSession?.videoFramesPerSecond = newValue }
    }
    /// The frame count and the moment it was read, for the difference above.
    var lastFrameSample: (count: Int, at: Date)? {
        get { activeSession?.lastFrameSample }
        set { activeSession?.lastFrameSample = newValue }
    }
    /// True while the video channel is delivering frames (not ended/absent).
    var isVideoStreaming: Bool {
        get { activeSession?.isVideoStreaming ?? false }
        set { activeSession?.isVideoStreaming = newValue }
    }
    /// Which channel the picture is arriving on. `.control` means the Mac's network is not
    /// letting video through and the session has fallen back — see ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport {
        get { activeSession?.videoTransport ?? .primary }
        set { activeSession?.videoTransport = newValue }
    }

    /// Which way this session's control connection is carried. See ``MacSession/connectionPath``.
    var connectionPath: ConnectionPath? {
        get { activeSession?.connectionPath }
        set { activeSession?.connectionPath = newValue }
    }

    /// Whether the picture is being carried straight between the two ends rather than around
    /// through the relay.
    var usedDirectPath: Bool {
        get { activeSession?.usedDirectPath ?? false }
        set { activeSession?.usedDirectPath = newValue }
    }

    /// What the attempt at a path straight to the Mac has come to.
    var directPathStatus: ClientSession.DirectPath {
        get { activeSession?.directPathStatus ?? .notTried }
        set { activeSession?.directPathStatus = newValue }
    }

    /// What the relay's datagram lane carried, kept after the session ends.
    var datagramCounts: ClientSession.DatagramCounts? {
        get { activeSession?.datagramCounts }
        set { activeSession?.datagramCounts = newValue }
    }

    /// The picture the stream is showing now, or `nil` before the Mac has described one.
    var picture: PictureIdentity? {
        get { activeSession?.picture }
        set { activeSession?.picture = newValue }
    }

    /// Something the Mac wants said about the picture, or `nil`.
    var remoteNotice: NoticePayload? {
        get { activeSession?.remoteNotice }
        set { activeSession?.remoteNotice = newValue }
    }

    /// When the session that is up now came up, for the elapsed-time readout.
    var sessionStartedAt: Date? {
        get { activeSession?.sessionStartedAt }
        set { activeSession?.sessionStartedAt = newValue }
    }

    /// Which capture source this session is showing.
    var activeSourceID: String? {
        get { activeSession?.activeSourceID }
        set { activeSession?.activeSourceID = newValue }
    }

    /// Optimistic state for the current session's physical-display privacy command.
    var privacyModeEnabled: Bool {
        get { activeSession?.privacyModeEnabled ?? false }
        set { activeSession?.privacyModeEnabled = newValue }
    }
    /// The quality the app is set to, read straight from the defaults.
    ///
    /// **The rule itself is ``MacCastKit/StreamQuality/stored(in:)``**, because it is a decoding
    /// rule rather than app state and there is a test for it that runs without an app bundle. This
    /// is the name the app knows it by.
    static var storedQuality: StreamQuality { .stored() }

    /// The bitrate preset. Stored rather than computed from the defaults, because every surface
    /// showing it has to redraw when it changes and a computed property reading `UserDefaults` is
    /// a change nothing observes — see ``terminalHistory``, which is here for the same reason.
    ///
    /// Seeded at init from ``storedQuality``, and written back by ``setStreamQuality(_:)``, which
    /// is also how the Settings tab's row reaches a session: that tab cannot be opened while one
    /// is running, so it writes the preference and the next arrival picks it up here.

    /// Writes a quality choice down, and nothing else.
    ///
    /// **The one place the preference is stored**, used by both doors into it: a live session,
    /// which also tells its Mac, and the Settings tab, which cannot reach one because that tab is
    /// unreachable while a session runs — see ``MacSession/setStreamQuality(_:)`` and
    /// ``MacSession/applyInitialQuality()``, which read this back through ``storedQuality`` on
    /// every arrival so that a change made there is not lost.
    func rememberQualityChoice(_ quality: StreamQuality) {
        streamQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: PreferenceKeys.streamQuality)
        // Remembered for ``setAutomaticQuality(_:)``: a level picked by hand is the one to return to.
        if quality.bitrateKbps != nil { lastManualQuality = quality }
    }

    /// The wire for the Mac the app is showing.
    ///
    /// A forwarder like the rest: the connection belongs to a session, and the app's screens
    /// ask for "the" one because there is only ever one to ask about.
    var session: ClientSession? {
        get { activeSession?.wire }
        set { activeSession?.wire = newValue }
    }

    /// The half-second poll that reads the renderer's counters.
    var videoPoll: Task<Void, Never>? {
        get { activeSession?.videoPoll }
        set { activeSession?.videoPoll = newValue }
    }

}
