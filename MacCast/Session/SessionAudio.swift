import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "pl.dmq.peering", category: "audio")

/// Holds the audio session for as long as there is a session.
/// Category and activation are taken when a session starts, not at the first frame: Picture in Picture will not start without a playback category and is asked for on the way out of the app, where there is no second chance.
/// `RemoteAudioPlayer` sets the same category when built; the overlap is deliberate so neither depends on the other.
/// `.playback` not `.ambient`: only it survives the silent switch and lets Picture in Picture start on its own.
@MainActor
final class SessionAudio {
    static let shared = SessionAudio()

    private var isActive = false

    private init() {}

    func begin() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers`: without it a `.playback` session interrupts every other app's audio on activation.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            isActive = true
        } catch {
            // Logged and carried on: a session whose audio will not activate has no sound, it does not fail.
            audioLog.error("could not take the audio session: \(String(describing: error), privacy: .public)")
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        // `notifyOthersOnDeactivation` tells the apps that made room they can have it back.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            audioLog.notice("the audio session was not released, so other apps may stay interrupted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
