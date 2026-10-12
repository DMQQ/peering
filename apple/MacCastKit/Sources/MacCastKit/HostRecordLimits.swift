import Foundation

/// What a Mac may make this phone remember about it. The values come off the wire and are written to UserDefaults, so each has a ceiling.
public enum HostRecordLimits {
    public static let maximumNameCharacters = 80
    public static let maximumMACAddresses = 8
    public static let maximumMACCharacters = 17
    public static let maximumHosts = 64

    public static func clippedName(_ name: String) -> String {
        String(name.prefix(maximumNameCharacters))
    }

    public static func clippedMACAddresses(_ addresses: [String]) -> [String] {
        Array(addresses.map { String($0.prefix(maximumMACCharacters)) }.prefix(maximumMACAddresses))
    }

    /// Makes room for one more host by dropping entries for Macs that are not paired. Paired Macs are never dropped, so a full table of them is returned as it is.
    public static func pruned<Value>(
        _ records: [String: Value],
        keeping pairedHostIDs: Set<String>
    ) -> [String: Value] {
        guard records.count > maximumHosts else { return records }
        return records.filter { pairedHostIDs.contains($0.key) }
    }
}
