import CoreMedia
import Foundation

struct ParameterSets: Sendable, Equatable {
    let sets: [Data]
    let nalUnitHeaderLength: Int
}

/// AVCC, not Annex-B: 4-byte big-endian NALU lengths with parameter sets out of band; both ends speak AVCC natively, so start codes would cost a rewrite of every frame.
struct EncodedFrame: Sendable {
    let data: Data
    let presentationTime: CMTime
    let duration: CMTime
    let isKeyframe: Bool
    /// Non-empty on keyframes. A new client cannot decode until it has these, so they are carried rather than re-derived.
    let parameterSets: [Data]
    let nalUnitHeaderLength: Int
    let codec: VideoCodec
    let pixelSize: CGSize
    /// The screen rectangle of this exact picture, kept through the asynchronous encoder so input
    /// is not remapped for a newer source or window position while the phone still shows this one.
    let geometry: FrameGeometry
}
