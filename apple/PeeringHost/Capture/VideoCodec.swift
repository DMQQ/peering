import CoreMedia
import Foundation
import VideoToolbox

enum VideoCodec: String, CaseIterable, Sendable, Equatable {
    case h264
    case hevc

    var title: String { rawValue.uppercased() }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264:
            // Main, not Baseline (no B-frames or CABAC, and nothing needs it). AutoLevel because a hardcoded level failed on a 5K display.
            return kVTProfileLevel_H264_Main_AutoLevel
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

    /// Per codec: the H.264 accessor returns nothing for an HEVC format description and vice versa.
    func parameterSets(from formatDescription: CMFormatDescription) -> ParameterSets? {
        switch self {
        case .h264:
            var sets: [Data] = []
            var nalUnitHeaderLength: Int32 = 0
            var index = 0

            while true {
                var pointer: UnsafePointer<UInt8>?
                var size: Int = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &nalUnitHeaderLength
                )
                guard status == noErr, let pointer, size > 0 else { break }
                sets.append(Data(bytes: pointer, count: size))
                index += 1
            }

            guard !sets.isEmpty else { return nil }
            return ParameterSets(sets: sets, nalUnitHeaderLength: Int(nalUnitHeaderLength))
        case .hevc:
            var sets: [Data] = []
            var nalUnitHeaderLength: Int32 = 0
            var index = 0
            while true {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &nalUnitHeaderLength
                )
                guard status == noErr, let pointer, size > 0 else { break }
                sets.append(Data(bytes: pointer, count: size))
                index += 1
            }
            guard !sets.isEmpty else { return nil }
            return ParameterSets(sets: sets, nalUnitHeaderLength: Int(nalUnitHeaderLength))
        }
    }
}
