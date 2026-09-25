import Foundation

// MARK: - Capture

extension HostModel {
    static let captureResolutionKey = "captureResolution"
    static let captureFrameRateKey = "captureFrameRate"
    static let captureCodecKey = "captureCodec"

    /// What the picture is made of: how many pixels a frame carries, and how many frames a second.
    ///
    /// A value this version cannot read falls back to the default rather than to the other case, so
    /// a key written by a later build cannot leave the stream smaller or slower than anyone chose.
    /// The frame rate needs no absence check: `integer(forKey:)` answers 0 for a key never written,
    /// and 0 is not a rate any stream can be built at.
    static func storedCaptureResolution() -> CaptureResolution {
        UserDefaults.standard.string(forKey: captureResolutionKey)
            .flatMap { CaptureResolution(rawValue: $0) } ?? .full
    }

    static func storedCaptureFrameRate() -> CaptureFrameRate {
        let stored = UserDefaults.standard.integer(forKey: captureFrameRateKey)
        return CaptureFrameRate(rawValue: stored) ?? .sixty
    }

    /// HEVC by default: every iPhone this app runs on decodes it in hardware (true since the
    /// 2015 A9), and `VideoEncoder` falls back to H.264 itself if this Mac's GPU cannot encode it.
    static func storedCaptureCodec() -> VideoCodec {
        UserDefaults.standard.string(forKey: captureCodecKey).flatMap(VideoCodec.init(rawValue:)) ?? .hevc
    }

    /// These take effect on the next stream, not on the one already running.
    ///
    /// A surface's size and its frame interval are fixed when the `SCStream` is built, so a capture
    /// in flight can only be replaced, which would drop the picture and cost a keyframe for a
    /// setting the user is still deciding on. Both define the capture and encoder timelines.
    func setCaptureResolution(_ resolution: CaptureResolution) {
        captureResolution = resolution
        UserDefaults.standard.set(resolution.rawValue, forKey: Self.captureResolutionKey)
        applyCaptureFormat()
    }

    func setCaptureFrameRate(_ frameRate: CaptureFrameRate) {
        captureFrameRate = frameRate
        UserDefaults.standard.set(frameRate.rawValue, forKey: Self.captureFrameRateKey)
        applyCaptureFormat()
    }

    func setCaptureCodec(_ codec: VideoCodec) {
        captureCodec = codec
        UserDefaults.standard.set(codec.rawValue, forKey: Self.captureCodecKey)
        record("Codec set to \(codec.title); it applies when the next stream starts")
    }

    /// Hands the pair to the coordinator, which reads them when a capture starts.
    ///
    /// Silent while nothing is listening, which is ordinary rather than a failure: the values live
    /// in the stored properties above and ``HostModel/start()`` gives a coordinator built afterwards
    /// both. Written as one call so a coordinator cannot build the next stream out of two moments.
    func applyCaptureFormat() {
        coordinator?.setCaptureFormat(resolution: captureResolution, frameRate: captureFrameRate)
    }
}
