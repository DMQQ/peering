import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI

extension SessionModel {

    // MARK: - The active session's state

    // Forwarders to the per-Mac state on ``MacSession``, for screens that still ask for "the" session.

    var hostName: String? {
        get { activeSession?.hostName }
        set { activeSession?.hostName = newValue }
    }

    /// ``hostName`` as the user renamed it, for anything drawn on screen.
    var shownHostName: String? { activeSession?.shownName }

    var currentHostID: String? {
        get { activeSession?.hostID }
        set { activeSession?.hostID = newValue }
    }

    var latencyMilliseconds: Double? {
        get { activeSession?.latencyMilliseconds }
        set { activeSession?.latencyMilliseconds = newValue }
    }

    var pathLatencyMilliseconds: Double? {
        get { activeSession?.pathLatencyMilliseconds }
        set { activeSession?.pathLatencyMilliseconds = newValue }
    }
    var pathLatencyIsDirect: Bool {
        get { activeSession?.pathLatencyIsDirect ?? false }
        set { activeSession?.pathLatencyIsDirect = newValue }
    }

    var catalog: CaptureCatalog? {
        get { activeSession?.catalog }
        set { activeSession?.catalog = newValue }
    }

    var notes: [String] {
        get { activeSession?.notes ?? [] }
        set { activeSession?.notes = newValue }
    }

    var mosaicLayout: MosaicLayout? { activeSession?.mosaicLayout }

    var pictureMosaicLayout: MosaicLayout? { activeSession?.pictureMosaicLayout }

    /// The Mac has something to build: unlike ``mosaicLayout``, which is rebuilt from the live catalogue and so moves its canvas on its own, this is frozen at the ask.
    var askedMosaicLayout: MosaicLayout? { activeSession?.askedMosaicLayout }

    var mosaicChoices: [MosaicChoice] {
        get { activeSession?.mosaicChoices ?? [] }
        set { activeSession?.mosaicChoices = newValue }
    }

    var mosaicViewport: CGSize { activeSession?.mosaicViewport ?? CGSize(width: 1280, height: 720) }

    var canReturnToMosaic: Bool { activeSession?.canReturnToMosaic ?? false }

    var isShowingMosaic: Bool { activeSession?.isShowingMosaic ?? false }

    /// The screen needs the ask as well as the answer: what the user just did is about the arrangement asked for, what is drawn on the picture is about the one that arrived.
    var isAskingForMosaic: Bool { activeSession?.isAskingForMosaic ?? false }

    var hostSupportsMosaic: Bool { activeSession?.hostSupportsMosaic ?? false }

    var hostSupportsSourceThumbnails: Bool { activeSession?.hostSupportsSourceThumbnails ?? false }

    var hostSupportsDeviceOrientation: Bool { activeSession?.hostSupportsDeviceOrientation ?? false }

    var hostSupportsVirtualDisplayManagement: Bool {
        activeSession?.hostSupportsVirtualDisplayManagement ?? false
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
        get { activeSession?.videoStatus ?? String(localized: "No video stream") }
        set { activeSession?.videoStatus = newValue }
    }
    var videoFramesPerSecond: Double {
        get { activeSession?.videoFramesPerSecond ?? 0 }
        set { activeSession?.videoFramesPerSecond = newValue }
    }
    var lastFrameSample: (count: Int, at: Date)? {
        get { activeSession?.lastFrameSample }
        set { activeSession?.lastFrameSample = newValue }
    }
    var isVideoStreaming: Bool {
        get { activeSession?.isVideoStreaming ?? false }
        set { activeSession?.isVideoStreaming = newValue }
    }
    /// `.control` means the Mac's network is not letting video through and the session fell back.
    var videoTransport: VideoTransport {
        get { activeSession?.videoTransport ?? .primary }
        set { activeSession?.videoTransport = newValue }
    }

    var connectionPath: ConnectionPath? {
        get { activeSession?.connectionPath }
        set { activeSession?.connectionPath = newValue }
    }

    var usedDirectPath: Bool {
        get { activeSession?.usedDirectPath ?? false }
        set { activeSession?.usedDirectPath = newValue }
    }

    var directPathStatus: ClientSession.DirectPath {
        get { activeSession?.directPathStatus ?? .notTried }
        set { activeSession?.directPathStatus = newValue }
    }

    var datagramCounts: ClientSession.DatagramCounts? {
        get { activeSession?.datagramCounts }
        set { activeSession?.datagramCounts = newValue }
    }

    var picture: PictureIdentity? {
        get { activeSession?.picture }
        set { activeSession?.picture = newValue }
    }

    var remoteNotice: NoticePayload? {
        get { activeSession?.remoteNotice }
        set { activeSession?.remoteNotice = newValue }
    }

    var sessionStartedAt: Date? {
        get { activeSession?.sessionStartedAt }
        set { activeSession?.sessionStartedAt = newValue }
    }

    var activeSourceID: String? {
        get { activeSession?.activeSourceID }
        set { activeSession?.activeSourceID = newValue }
    }

    var privacyModeEnabled: Bool {
        get { activeSession?.privacyModeEnabled ?? false }
        set { activeSession?.privacyModeEnabled = newValue }
    }
    static var storedQuality: StreamQuality { .stored() }

    /// Stored, not computed from the defaults: surfaces must redraw on change, and nothing observes `UserDefaults`.
    /// Seeded from `storedQuality`; the Settings tab, unreachable mid-session, writes the preference and the next arrival picks it up.

    func rememberQualityChoice(_ quality: StreamQuality) {
        streamQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: PreferenceKeys.streamQuality)
        // Remembered for ``setAutomaticQuality(_:)``: a level picked by hand is the one to return to.
        if quality.bitrateKbps != nil { lastManualQuality = quality }
    }

    var session: ClientSession? {
        get { activeSession?.wire }
        set { activeSession?.wire = newValue }
    }

    var videoPoll: Task<Void, Never>? {
        get { activeSession?.videoPoll }
        set { activeSession?.videoPoll = newValue }
    }

    // MARK: - Clipboard
    var hostClipboard: ClipboardPayload? {
        get { activeSession?.hostClipboard }
        set { activeSession?.hostClipboard = newValue }
    }

    var clipboardPulling: Bool {
        get { activeSession?.clipboardPulling ?? false }
        set { activeSession?.clipboardPulling = newValue }
    }

    // MARK: - Audio

    /// One Mac's sound at a time.
    var audioPlayer: RemoteAudioPlayer? {
        get { activeSession?.audioPlayer }
        set { activeSession?.audioPlayer = newValue }
    }

    var playsHostAudio: Bool { !hostAudioMuted }

    // MARK: - Terminals

    var terminals: [RemoteTerminal] {
        get { activeSession?.terminals ?? [] }
        set { activeSession?.terminals = newValue }
    }

    var selectedTerminalID: UUID? {
        get { activeSession?.selectedTerminalID }
        set { activeSession?.selectedTerminalID = newValue }
    }

    // MARK: - File browsing

    var directories: [RemoteDirectoryKey: RemoteDirectory] {
        get { activeSession?.directories ?? [:] }
        set { activeSession?.directories = newValue }
    }

    var browsingPaths: [UUID: String] {
        get { activeSession?.browsingPaths ?? [:] }
        set { activeSession?.browsingPaths = newValue }
    }

    var pendingDirectories: Set<RemoteDirectoryKey> {
        get { activeSession?.pendingDirectories ?? [] }
        set { activeSession?.pendingDirectories = newValue }
    }

    var browseFailures: [RemoteDirectoryKey: String] {
        get { activeSession?.browseFailures ?? [:] }
        set { activeSession?.browseFailures = newValue }
    }

    var filePreview: RemoteFilePreview? {
        get { activeSession?.filePreview }
        set { activeSession?.filePreview = newValue }
    }

    var pendingRun: String? {
        get { activeSession?.pendingRun }
        set { activeSession?.pendingRun = newValue }
    }

    var writes: [UUID: FileWrite] {
        get { activeSession?.writes ?? [:] }
        set { activeSession?.writes = newValue }
    }

    var saveFailures: [UUID: String] {
        get { activeSession?.saveFailures ?? [:] }
        set { activeSession?.saveFailures = newValue }
    }
    var uploadFailures: [UUID: String] {
        get { activeSession?.uploadFailures ?? [:] }
        set { activeSession?.uploadFailures = newValue }
    }

    var changes: [UUID: FileChange] {
        get { activeSession?.changes ?? [:] }
        set { activeSession?.changes = newValue }
    }

    var changeFailures: [UUID: String] {
        get { activeSession?.changeFailures ?? [:] }
        set { activeSession?.changeFailures = newValue }
    }
}
