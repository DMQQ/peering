import Foundation

/// How Low Power Mode changes the picture. The host does not act on the frame rate field of `setStreamQuality`, so the bitrate ceiling is the whole lever.
public enum PowerSavingPolicy {
    public static let lowPowerCeiling = AutoQualityPolicy.Tier.medium

    public static func ceiling(_ base: AutoQualityPolicy.Tier, isLowPowerMode: Bool) -> AutoQualityPolicy.Tier {
        guard isLowPowerMode, base.rank > lowPowerCeiling.rank else { return base }
        return lowPowerCeiling
    }
}
