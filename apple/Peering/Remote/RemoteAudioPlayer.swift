import AVFoundation
import Foundation
import os
import RemoteCore

private nonisolated let audioLog = Logger(subsystem: "pl.dmq.peering", category: "audio")

final class RemoteAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let channelCount: Int

    init?(config: AudioStreamConfig) {
        guard config.codec == .pcmFloat32,
              config.sampleRate.isFinite,
              (8_000...384_000).contains(config.sampleRate),
              (1...32).contains(config.channelCount),
              let fmt = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: config.sampleRate,
                  channels: AVAudioChannelCount(config.channelCount),
                  interleaved: false
              )
        else { return nil }
        self.format = fmt
        self.channelCount = config.channelCount

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            // Same category, mode and options as ``SessionAudio``, and not set again when they already hold: a second, different configuration is a route change to every other app playing, and YouTube Music paused for it.
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.mode != .moviePlayback || !session.categoryOptions.contains(.mixWithOthers) {
                try session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            }
            try session.setActive(true)
            try engine.start()
            playerNode.play()
            // Taking the microphone for dictation reroutes the session, which stops an engine without telling anyone: the sound stayed gone until the next connection.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.resumeAfterRouteChange() }
        } catch {
            Analytics.failed(error, in: .audio)
            audioLog.error("could not start the audio engine: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?

    private func resumeAfterRouteChange() {
        guard !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            playerNode.play()
        } catch {
            Analytics.failed(error, in: .audio)
            audioLog.error("could not restart the audio engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        playerNode.stop()
        engine.stop()
    }

    /// The sound that prompted it: macOS plays its alert — the "woop" — when a chord it was
    /// given leads nowhere, such as going back through a history that has nothing in it. An
    /// injected ⌘[ is a real key press and gets the real alert, and then the phone plays it back
    /// at the person who pressed it. There is no way to ask macOS not to, so the way out is to
    /// stop playing what it says.
    var isMuted = false {
        didSet { engine.mainMixerNode.outputVolume = isMuted ? 0 : 1 }
    }

    func enqueue(_ frame: EncodedAudioFrame) {
        let (sampleValues, sampleOverflow) = frame.sampleCount.multipliedReportingOverflow(by: channelCount)
        let (expectedBytes, byteOverflow) = sampleValues.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard frame.channelCount == channelCount,
              frame.sampleCount > 0,
              !sampleOverflow,
              !byteOverflow,
              frame.samples.count == expectedBytes
        else { return }
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        // De-interleave: input is L0 R0 L1 R1 …, AVAudioPCMBuffer expects channel planes.
        frame.samples.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for ch in 0..<channelCount {
                guard let plane = buffer.floatChannelData?[ch] else { continue }
                for i in 0..<Int(frameCount) {
                    let idx = i * channelCount + ch
                    plane[i] = idx < floats.count ? floats[idx] : 0
                }
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
}
