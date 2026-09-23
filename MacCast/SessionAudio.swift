import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "pl.dmq.peering", category: "audio")

/// Holds the audio session for as long as there is a session.
///
/// **What this used to be, and why it is not that any more.** It played a second of generated
/// silence on a loop, for exactly as long as a session was up, because iOS suspends an app with
/// nothing to do and a suspended app's sockets die. That is a background-mode trick by
/// definition: the app was not playing anything, it was staying awake, and the old comment here
/// said as much. What replaced it is the audio the app actually has. The Mac's own sound is
/// played by ``RemoteAudioPlayer`` for the whole session, which is what the `audio` background
/// mode in `Config/MacCast-Info.plist` is honestly for, beside Picture in Picture.
///
/// What is left here is the session's category and its activation, taken once when a session
/// starts rather than when its first frame arrives. Two things want it that early. Picture in
/// Picture will not start without a playback category, and it is asked for on the way out of the
/// app, where there is no second chance. And a first frame that has to wait for an activation is
/// a first frame that arrives late, which for a sound is the difference between hearing it and
/// hearing where it should have started.
///
/// ``RemoteAudioPlayer`` sets the same category when it is built, and the overlap is deliberate:
/// either one alone is enough for the audio to work, so neither depends on the other having run.
///
/// The category is `.playback` rather than `.ambient` because it has to be: that is the one that
/// survives the silent switch and lets Picture in Picture start on its own.
@MainActor
final class SessionAudio {
    static let shared = SessionAudio()

    private var isActive = false

    private init() {}

    /// Takes the session. Idempotent, so it can be called on every phase change.
    func begin() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers`, and without it this silences whatever the user was listening to.
            //
            // A `.playback` session that does not mix *interrupts* every other app's audio the
            // moment it activates: iOS tells them to stop, and they do. The Mac's sound is worth
            // playing alongside somebody's music, not worth cutting it off for.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            isActive = true
        } catch {
            // Logged and carried on. A session whose audio will not activate is a session with
            // no sound, not a session that fails, and the picture is the part being paid for.
            audioLog.error("could not take the audio session: \(String(describing: error), privacy: .public)")
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        // `notifyOthersOnDeactivation`: the apps that made room are told they can have it back.
        // Without it the interruption outlives the session that caused it.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            audioLog.notice("the audio session was not released, so other apps may stay interrupted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
