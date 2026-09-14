import Foundation

/// Constants shared by the host and the client, so neither can drift from the other.
public enum ProtocolInfo {
    /// Bumped whenever the wire format changes incompatibly. Exchanged in the hello
    /// messages and bound into the pairing transcript.
    public static let version: UInt16 = 1

    /// Bonjour service type. Must also appear in the client's `NSBonjourServices`
    /// Info.plist key, or browsing fails silently with no prompt and no error.
    public static let bonjourServiceType = "_remotedesktop._tcp"

    /// The single port the host listens on. Both the control and video connections
    /// arrive here; the first frame on each declares which one it is.
    public static let defaultPort: UInt16 = 51515

    /// TXT record keys advertised over Bonjour, so a client can show a useful device
    /// list before connecting.
    public enum TXTRecordKey {
        public static let deviceID = "id"
        public static let deviceName = "name"
        public static let protocolVersion = "v"
    }
}
