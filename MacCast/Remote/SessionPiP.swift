import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import VideoToolbox
import os

/// Picture in Picture shares the in-app `AVSampleBufferDisplayLayer`, so there is no second decode. Watch-only: the floating window is iOS's, touches never reach the Mac.
@MainActor
@Observable
final class SessionPiP: NSObject {
    static let shared = SessionPiP()

    /// Our own switch because the system's is buried in Settings. Both must allow auto start; this one speaks only for the app. 
    var autoStart =
        UserDefaults.standard.object(forKey: PreferenceKeys.pipAutoStart) as? Bool ?? true {
        didSet { applyAutoStart() }
    }

    /// Writes the preference onto the armed controller. Called from ``autoStart`` and ``attach(_:)`` since the controller is replaced per session.
    private func applyAutoStart() {
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart
    }

    /// Recorded on success too: `enteringBackground` may never reach `start`, and silence looks the same either way.
    private(set) var lastAttempt: String?

    /// PiP refuses without naming the missing prerequisite, so the reason is shown on screen.
    private(set) var lastRefusal: String?

    private var controller: AVPictureInPictureController?

    /// Held weakly: `RemoteScreen` is rebuilt per session and a strong ref would keep a torn-down view and its layer alive.
    private weak var host: VideoDisplayView?

    private override init() { super.init() }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Where the app was when it asked: separates a broken PiP from one asked at a moment it does not answer. `applicationState` keeps answering as the app leaves.
    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return String(localized: "foreground")
        case .inactive: return String(localized: "on its way out")
        case .background: return String(localized: "background")
        @unknown default: return String(localized: "in an unknown state")
        }
    }

    /// AVKit's own error domain and code for the one failure it explains itself; read in the delegate's `failedToStart` only.
    private static let pictureInPictureErrorDomain = "AVKitErrorDomain"
    private static let sceneNotForegroundCode = -1001

    /// Rebinding on every session: a controller built once on the first session's layer (the `controller == nil` guard) made every later start refuse against a torn-down layer, intermittently.
    func attach(_ view: VideoDisplayView) {
        guard Self.isSupported, host !== view else { return }

        // Stop PiP first: a window left up on a layer nobody owns shows the last session frozen.
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller = nil
        host = view

        guard let layer = view.displayLayer else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        // Removes fast-forward, forward-skip and scrubber (a live picture has no ahead). Play/pause and backward-skip have no switch; the delegate's `IsPlaybackPaused` reports false and backward-skip completes immediately.
        controller.requiresLinearPlayback = true
        // Set for the failure callback: without a delegate, a refusal to start is silent.
        controller.delegate = self
        self.controller = controller
        // Last because it writes the switch onto the controller; going to another app then floats the picture instead of ending the session.
        applyAutoStart()
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// The only place the automatic case can be observed; recorded either way, since never tried and refused both look like silence.
    func backgrounding(sessionIsUp: Bool) {
        guard sessionIsUp else {
            lastAttempt = String(localized: "app left screen with no session up")
            return
        }
        start()
    }

    /// Starts now, to try it without leaving and to say why it will not start.
    func start() {
        guard let controller else {
            lastRefusal = String(localized: "No picture yet. PiP mirrors the video layer, so a session has to be running.")
            lastAttempt = String(localized: "no layer")
            videoLog.error("Picture in Picture has no layer to mirror yet")
            return
        }
        // Answered first: a running PiP lifts the layer out of the view hierarchy, so the window checks below would misread it as absent.
        if controller.isPictureInPictureActive {
            lastRefusal = nil
            lastAttempt = String(localized: "already active")
            return
        }
        // Checked before `isPictureInPicturePossible`, which does not re-evaluate this: it kept reporting possible for a layer torn down with its screen.
        guard let host, host.window != nil else {
            lastRefusal = """
                The video is not on screen any more. PiP lifts the layer out of the view it is \
                drawn in, so it has to be in one when it is asked. Asked while \(Self.appState).
                """
            lastAttempt = String(localized: "no screen to lift the layer out of")
            videoLog.error("Picture in Picture has no window: \(self.lastRefusal ?? "", privacy: .public)")
            return
        }
        guard controller.isPictureInPicturePossible else {
            // One line with every prerequisite since PiP refuses without saying which: layer in a visible view, audio session active, video actually rendering.
            let audio = AVAudioSession.sharedInstance()
            lastRefusal = """
                Not supported here. Supported \(Self.isSupported ? "yes" : "no"), \
                audio category \(audio.category.rawValue), running \(!audio.isOtherAudioPlaying), \
                asked while \(Self.appState)
                """
            lastAttempt = String(localized: "not possible")
            videoLog.error("Picture in Picture is not possible: \(self.lastRefusal ?? "", privacy: .public)")
            return
        }
        lastRefusal = nil
        // Where it was asked is part of the record: a refusal names nothing, so app state is the only difference.
        lastAttempt = String(localized: "asked while \(Self.appState)")
        videoLog.notice("Asking for Picture in Picture while \(Self.appState, privacy: .public)")
        Analytics.featureUsed(.pipStarted)
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// Stops the floating window and releases the content source; a later `attach` builds a controller for the next session.
    func detach() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        host = nil
    }
}

extension SessionPiP: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        videoLog.notice("Picture in Picture started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        videoLog.notice("Picture in Picture stopped")
    }

    /// The session screen never left the hierarchy, so tell AVKit restoration is ready when the user taps return.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // No route to rebuild and nothing to await, so restoration succeeded.
        completionHandler(true)
    }

    /// The only place any PiP refusal is named.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let failure = error as NSError

        // `AVKitErrorDomain` -1001 "Failed to start picture in picture." has exactly one cause: the content source's scene is not foreground active.
        // Expected for the call made on the way out, since `enteringBackground` runs after leaving the foreground, so the sentence is replaced with its meaning. A -1001 is a timing fact, never wiring; other failures arrive silently or under a different domain.
        if failure.domain == Self.pictureInPictureErrorDomain,
           failure.code == Self.sceneNotForegroundCode {
            lastRefusal = """
                iOS only starts Picture in Picture for an app that is on screen, and this ask \
                was made while \(Self.appState). Asking on the way out cannot work. Arriving \
                unasked is the automatic start's job, and that needs "Start PiP Automatically" \
                on under Settings → General → Picture in Picture.
                """
        } else {
            lastRefusal = """
                Could not start: \(error.localizedDescription) \
                (\(failure.domain) \(failure.code)), asked while \(Self.appState)
                """
        }

        lastAttempt = "failed"
        videoLog.error("""
            Picture in Picture could not start: \(error.localizedDescription, privacy: .public) \
            \(failure.domain, privacy: .public) \(failure.code, privacy: .public), \
            asked while \(Self.appState, privacy: .public), \
            reason \(failure.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "none given", privacy: .public)
            """)
    }
}

extension SessionPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    // nonisolated: AVKit may call these from its own queue, and a MainActor method called off the main actor traps. None of them touches state.
    /// Live content, infinite duration. Returning `kCMTimeRangeInvalid` for no content was tried and iOS renders it as a loading spinner over a frozen picture. Transport controls stay; `requiresLinearPlayback` removes some, see ``SessionPiP``.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    /// Never paused: holding frames back is a dropped frame, not a pause.
    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
