import MacCastKit
import RemoteCore

extension MacSession {
    /// Not `phase.holdsSession` alone: a dropped Mac being retried is still open. `hasBeenReady` stops a dial that failed before its handshake, which arms the same ladder, from counting as an open Mac and spending the free plan's allowance.
    var isLive: Bool { phase.holdsSession || (hasBeenReady && isReconnecting) }

    var isActive: Bool { model.activeSessionID == id }

    /// The second half is why this is not ``SessionModel/isSessionOnScreen``: a Picture in Picture window is somebody still watching from outside the app, so stepping back to the picker must not freeze it. See ``SessionModel/stepAwayFromSession()``.
    var isWatched: Bool { model.isSessionOnScreen || SessionPiP.shared.isActive }

    /// Being the Mac on screen decides whose sound plays, else two Macs open at once are two audio engines into one pair of ears (a Mac behind the one on screen is silent). Being watched decides whether anything is heard: a session the user stepped away from is still connected with its player. See ``isWatched``.
    var shouldPlayAudio: Bool { isActive && isWatched && model.playsHostAudio }

    /// Called when a config arrives and when the active Mac changes: a player built for the Mac on screen keeps playing after the user looks away unless told.
    func refreshAudioMuteState() {
        audioPlayer?.isMuted = !shouldPlayAudio
    }

    var sourceToResume: CaptureSource? {
        if activeSourceID?.hasPrefix("mosaic:") == true {
            return askedMosaicLayout.map { .mosaic($0) }
        }
        return catalog?.all.first { $0.id == activeSourceID }?.source
    }

    var mosaicTileAspect: Double { tileAspect(for: mosaicChoices) }

    var isShowingMosaic: Bool { pictureMosaicLayout != nil }

    // MARK: - Quality

    var isAutomaticQuality: Bool { model.streamQuality == .auto }

    struct FileWrite: Equatable {
        /// A save reads the file back so the editor shows what is on disk; an upload asks for the folder again so the file appears. Otherwise the same operation, hence one record.
        enum Door { case save, upload }

        let door: Door
        /// What the Mac's answer is matched on, since it names the file it wrote.
        let path: String
    }

    struct FileChange: Equatable {
        /// Held rather than only the path: the answer says what happened but not what was asked, and a rename's path is built from both.
        let operation: RemoteFileOperation
        /// The file's own path for a rename, not the one it becomes: the Mac's answer echoes what it was sent, and is matched on this.
        let path: String
    }
}
