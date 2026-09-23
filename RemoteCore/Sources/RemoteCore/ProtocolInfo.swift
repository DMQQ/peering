import Foundation

/// Constants shared by the host and the client, so neither can drift from the other.
public enum ProtocolInfo {
    /// Bumped whenever the wire format changes incompatibly. Exchanged in the hello
    /// messages and bound into the pairing transcript.
    ///
    /// An unknown command is a decode failure in the middle of a session rather than a degraded
    /// experience, so an incompatible change is declared here and the handshake turns a mixed pair
    /// into "update whichever is older".
    ///
    /// 2: `SpaceInfo` describes every display rather than one, and `switchToSpace` names the display
    /// it acts on; an older host cannot decode either.
    /// 3: adds relay signalling and routed control/video transports.
    /// 4: adds `refreshSpacePreviews`, which a host of version 3 cannot decode.
    /// 6: `SpaceDisplay` counts and numbers *desktops*, and `current` becomes optional because a
    /// display showing a fullscreen application has no current desktop. A 5 client reads a missing
    /// `current` as a decode failure and loses the whole catalogue.
    /// 5: adds `notice`, the host's way of captioning a healthy picture, a sleeping screen most of
    /// all. An older client would ignore the frame, which is survivable, but a 4 host would never
    /// send one and the phone would keep showing black with no explanation.
    /// 7: adds `setPrivacyMode`. An older host cannot decode the new command, so the handshake
    /// rejects a mixed pair with an update message instead of dropping an active session.
    /// 8: adds `lockScreen`, with the same compatibility requirement.
    /// 9: adds `clipboardContent` (frame kind 0x11), `requestClipboard` / `pushClipboard`
    /// (commands), `audioConfig` (0x13), `audioFrame` (0x14), and Wake-on-LAN MAC addresses in
    /// `ServerHello`. An older host cannot decode the new commands.
    /// 10: adds authenticated, reconnectable terminal sessions on the control channel.
    /// 11: adds directory browsing and file preview to that channel: `listDirectory` and `readFile`
    /// requests, and the `directory`, `fileContents` and `browseFailure` events that answer them. A
    /// 10 host cannot decode either request.
    /// 12: adds the control-channel video fallback, `videoChunk` (0x17) and `videoTransport` (0x18),
    /// for the networks that carry the control channel and drop everything else. The picture then
    /// arrives the only way it can. An 11 host cannot decode either message and would never send
    /// one, so a mixed pair would sit with the status saying connected and the screen empty.
    /// 13: moves relayed video off the control channel and onto the relay's datagram path:
    /// `videoKeyRequest` (0x19) and `videoKey` (0x1A) carry the secret both ends seal those
    /// datagrams with. A 12 host cannot decode either message and answers its datagrams with
    /// nothing, leaving the picture on the shared stream the client was trying to leave.
    /// 14: adds writing to that same channel: `beginWrite` and `writeChunk` requests, and the
    /// `wroteFile` and `writeFailure` events that answer them. A 13 host cannot decode either
    /// request, and the failure would land in the middle of an edit as a dropped session.
    /// 15: pictures join text in the browser. `fileContents` gains a `kind`, and a file that is an
    /// image is no longer refused. A 14 client cannot decode the new field: `RemoteFilePreview.text`
    /// decodes whatever it is given as UTF-8, so a photograph's bytes would arrive as a screen of
    /// replacement characters.
    /// 16: the browser can change things, not only read them. `changeFile` carries a
    /// `RemoteFileOperation` (make a file or folder, rename one, delete one), and the
    /// `fileOperationDone` and `fileOperationFailure` events answer it. A 15 host cannot decode the
    /// request, and the row would stay on screen because nothing ever answers.
    /// 17: the phone tells the Mac where to reach it when no session is up. `registerPushToken`
    /// carries the APNs device token, and its absence of a decoder is fatal rather than quiet: it is
    /// sent on every session becoming ready, so a host that does not know the case ends the session
    /// tens of milliseconds after it opens, and the phone redials into the same wall.
    ///
    /// Not 18, and the mosaic is why: `CaptureSource` gains a case an older host cannot decode, but it
    /// is only ever sent by the client, so a Mac that has not said it can take one never receives one
    /// and nothing already on the wire changes shape. That entry is in
    /// ``ServerHello/supportsMosaic`` instead, on the `supportsVideoPause` pattern.
    public static let version: UInt16 = 17

    /// The largest payload a control-channel message may carry.
    ///
    /// It is a rule about sending and the enforcement is on the receiving side: a host rejects an
    /// oversized command, but nothing refuses to produce one. The video fallback routinely has
    /// payloads larger than this, which is why it cuts them up rather than trusting the far end's
    /// buffer to be as large as the phone's.
    public static let maxControlPayload = 64 * 1024

    /// Public signalling endpoint. Control and video endpoints are supplied per session by the
    /// relay, so only this address belongs in the apps.
    public static let relaySignallingURL = URL(string: "wss://getpeering.app/")!

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
