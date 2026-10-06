import Foundation

/// Constants shared by the host and the client, so neither can drift from the other.
public enum ProtocolInfo {
    /// Bumped on every incompatible wire change; the handshake requires exact equality and tells a mixed pair to update whichever is older.
    /// 2: `SpaceInfo` covers every display; `switchToSpace` names its display.
    /// 3: adds relay signalling and routed control/video transports.
    /// 4: adds `refreshSpacePreviews`, which a host of version 3 cannot decode.
    /// 6: `SpaceDisplay` counts desktops; `current` becomes optional (a fullscreen display has none).
    /// 5: adds `notice`, captioning a healthy picture such as a sleeping screen.
    /// 7: adds `setPrivacyMode`.
    /// 8: adds `lockScreen`.
    /// 9: clipboard frames and commands, audio config and frames, Wake-on-LAN MACs in `ServerHello`.
    /// 10: adds authenticated, reconnectable terminal sessions on the control channel.
    /// 11: directory browsing and file preview: `listDirectory`, `readFile` and their events.
    /// 12: control-channel video fallback: `videoChunk` (0x17), `videoTransport` (0x18).
    /// 13: relayed video moves to the relay's datagram path: `videoKeyRequest` (0x19), `videoKey` (0x1A).
    /// 14: file writing: `beginWrite`, `writeChunk`, `wroteFile`, `writeFailure`.
    /// 15: `fileContents` gains a `kind`; images are no longer refused.
    /// 16: `changeFile` carries a `RemoteFileOperation`, answered by `fileOperationDone` and `fileOperationFailure`.
    /// 17: `registerPushToken` carries the APNs token; sent on every ready session, so an old host would end it at once.
    /// 18: `VideoStreamConfig` names the capture source its frames belong to.
    /// 19: `performWindowAction` and `openNewWindow`, the title-bar buttons and ⌘N from the phone.
    /// 20: `watchSourceThumbnails`, the picker telling the host it is open so the host pushes
    /// changed thumbnails instead of the phone asking.
    ///
    /// The mosaic feature itself did not consume a protocol version: `CaptureSource` gained a case an
    /// older host cannot decode, but it is only sent after that host advertises `supportsMosaic`.
    public static let version: UInt16 = 20

    /// Enforced on the receiving side only: nothing refuses to produce an oversized command, which is why the video fallback cuts payloads up.
    public static let maxControlPayload = 64 * 1024

    /// Control and video endpoints are supplied per session by the relay; only this address belongs in the apps.
    public static let relaySignallingURL = URL(string: "wss://getpeering.app/")!

    /// Bonjour service type. Must also appear in the client's `NSBonjourServices`
    /// Info.plist key, or browsing fails silently with no prompt and no error.
    public static let bonjourServiceType = "_remotedesktop._tcp"

    public static let defaultPort: UInt16 = 51515

    public enum TXTRecordKey {
        public static let deviceID = "id"
        public static let deviceName = "name"
        public static let protocolVersion = "v"
    }
}
