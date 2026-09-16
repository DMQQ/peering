import AVFoundation
import Foundation
import RemoteCore

/// Renders incoming PCM audio frames from a Mac session.
///
/// Built once per audio stream (one ``AudioStreamConfig`` → one player), so a stream
/// restart — codec change, sample rate change — starts a fresh instance. The old one
/// is simply released; AVAudioEngine cleans up on deinit.
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
            // Allow other audio sessions (music, calls) to continue alongside.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            playerNode.play()
        } catch {
            return nil
        }
    }

    deinit {
        playerNode.stop()
        engine.stop()
    }

    /// Converts interleaved Float32 samples to a non-interleaved AVAudioPCMBuffer and schedules
    /// them for playback.
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
