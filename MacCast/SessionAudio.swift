import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "pl.dmq.peering", category: "audio")

/// Keeps the app running while a session is up and the app is not on screen.
///
/// iOS suspends an app that has nothing to do, and a suspended app's sockets die — which is
/// what ended every session the moment the phone was locked or another app was opened. There is
/// no background mode a remote desktop can honestly claim, so this claims the one that works:
/// `audio`, on the `UIBackgroundModes` entry in `Config/MacCast-Info.plist`, with silence
/// playing for exactly as long as there is a session to keep.
///
/// **This is a compromise, and worth naming as one.** It keeps the radio and the CPU awake for
/// the whole time the app is backgrounded with a session up, and silent-audio keepalives are
/// the specific thing Apple rejects apps for. Both are acceptable for a personal, sideloaded
/// tool and neither would be for anything shipped.
///
/// The category is `.playback` rather than `.ambient` because it has to be: that is the one
/// that both survives the silent switch and permits Picture in Picture to start on its own.
@MainActor
final class SessionAudio {
    static let shared = SessionAudio()

    private var player: AVAudioPlayer?

    private init() {}

    /// Starts the keepalive. Idempotent, so it can be called on every phase change.
    func begin() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silence)
            // Looping rather than a long file: nothing schedules a restart when the app is in
            // the background, so a file that ends ends the keepalive with it.
            player.numberOfLoops = -1
            player.play()
            self.player = player
        } catch {
            // Logged and carried on. A session that cannot hold itself open in the background
            // is the behaviour this app had until today, not a new failure.
            audioLog.error("could not start the background keepalive: \(String(describing: error), privacy: .public)")
        }
    }

    func end() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One second of sixteen-bit mono silence, as a WAV.
    ///
    /// Built rather than shipped. A file in the bundle would be a resource whose entire content
    /// is nothing, and one more thing to keep in step with the target's membership.
    private static var silence: Data {
        let sampleRate: UInt32 = 44_100
        let sampleCount = Int(sampleRate)
        let payloadBytes = UInt32(sampleCount * 2)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendASCII(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }

        appendASCII("RIFF")
        append(UInt32(36) + payloadBytes)
        appendASCII("WAVEfmt ")
        append(UInt32(16))          // PCM header length
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(sampleRate)
        append(sampleRate * 2)      // byte rate: one channel, two bytes per sample
        append(UInt16(2))           // block align
        append(UInt16(16))          // bits per sample
        appendASCII("data")
        append(payloadBytes)
        data.append(Data(count: sampleCount * 2))
        return data
    }
}
