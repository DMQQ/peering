/// Bounds on what a client may ask the encoder for. The numbers arrive off the wire, so the host
/// clamps them rather than trusting the phone to stay sane.
public enum StreamQualityLimits {
    public static let maxBitrateKbps = 100_000

    /// `nil` for a request that is not a bitrate at all (zero or negative).
    public static func clampedBitrateKbps(_ requested: Int) -> Int? {
        requested > 0 ? min(requested, maxBitrateKbps) : nil
    }
}
