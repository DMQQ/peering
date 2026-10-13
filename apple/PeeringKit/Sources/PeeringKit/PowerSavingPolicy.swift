import Foundation
import RemoteCore

/// How Low Power Mode changes the picture: a lower bitrate ceiling and a frame rate cap the Mac applies to what it sends.
public enum PowerSavingPolicy {
    public static let lowPowerCeiling = AutoQualityPolicy.Tier.medium
    public static let lowPowerFramesPerSecond = 30

    public static func ceiling(_ base: AutoQualityPolicy.Tier, isLowPowerMode: Bool) -> AutoQualityPolicy.Tier {
        guard isLowPowerMode, base.rank > lowPowerCeiling.rank else { return base }
        return lowPowerCeiling
    }

    /// Always a number, never "keep current": turning Low Power Mode off has to lift a cap the Mac is still holding.
    public static func framesPerSecond(isLowPowerMode: Bool) -> Int {
        isLowPowerMode ? lowPowerFramesPerSecond : StreamQualityLimits.maxFramesPerSecond
    }
}
