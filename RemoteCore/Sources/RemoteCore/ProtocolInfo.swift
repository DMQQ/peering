import Foundation

/// Constants shared by the host and the client, so neither can drift from the other.
public enum ProtocolInfo {
    /// Bumped whenever the wire format changes incompatibly. Exchanged in the hello
    /// messages and bound into the pairing transcript.
    ///
    /// 2: `SpaceInfo` describes every display rather than one, and `switchToSpace` names the
    /// display it acts on. An older host cannot decode either, so this is an incompatible change
    /// and is declared as one — the handshake turns it into "update whichever is older" rather
    /// than a decode failure in the middle of a session.
    /// 3: adds relay signalling and routed control/video transports.
    /// 4: adds `refreshSpacePreviews`, which a host of version 3 cannot decode. An unknown
    /// command is a decode failure in the middle of a session rather than a degraded
    /// experience, so this is declared incompatible for the usual reason: the handshake turns
    /// it into "update whichever is older".
    /// 6: `SpaceDisplay` counts and numbers *desktops*, and `current` becomes optional because
    /// a display showing a fullscreen application has no current desktop. A 5 client would read
    /// a missing `current` as a decode failure and lose the whole catalogue, so this is
    /// declared incompatible like the rest.
    /// 5: adds `notice`, the host's way of captioning a healthy picture — a sleeping screen,
    /// most of all. An older client would ignore the frame, which is survivable, but a 4 host
    /// would never send one and the phone would keep showing black with no explanation, which
    /// is the failure this exists to remove. Bumped, like the others, so the two ends are
    /// known to agree rather than assumed to.
    /// 7: adds `setPrivacyMode`. An older host cannot decode the new command, so the handshake
    /// rejects a mixed pair with an update message instead of dropping an active session.
    /// 8: adds `lockScreen`, with the same compatibility requirement.
    /// 9: adds `clipboardContent` (frame kind 0x11), `requestClipboard` / `pushClipboard`
    /// (commands), `audioConfig` (0x13), `audioFrame` (0x14), and Wake-on-LAN MAC addresses
    /// in `ServerHello`. An older host cannot decode the new commands; bump required.
    /// 10: adds authenticated, reconnectable terminal sessions on the control channel.
    /// 11: adds directory browsing and file preview to that channel — `listDirectory` and
    /// `readFile` requests, and the `directory`, `fileContents` and `browseFailure` events that
    /// answer them. A 10 host cannot decode either request, so this is declared incompatible for
    /// the usual reason: the handshake turns a mixed pair into an update message rather than a
    /// decode failure in the middle of a session.
    /// 12: adds the control-channel video fallback — `videoChunk` (0x17) and `videoTransport`
    /// (0x18) — for the networks that carry the control channel and drop everything else. The
    /// picture then arrives the only way it can. An 11 host cannot decode either message and,
    /// more to the point, would never send one: a mixed pair would spend the session in exactly
    /// the state this removes, with the status saying connected and the screen showing nothing.
    /// Declared incompatible like the rest, so the handshake turns it into "update whichever is
    /// older" rather than into a session that looks like it is working.
    /// 13: moves relayed video off the control channel and onto the relay's datagram path —
    /// `videoKeyRequest` (0x19) and `videoKey` (0x1A) carry the secret both ends seal those
    /// datagrams with. A 12 host cannot decode either message and, more to the point, answers
    /// its datagrams with nothing: a 13 client on a 12 host would ask for a key, get silence,
    /// and be left with the picture on the shared stream it was trying to leave. The version
    /// is what turns that into an update message at the door.
    public static let version: UInt16 = 13

    /// The largest payload a control-channel message may carry.
    ///
    /// Shared because it is a rule about *sending*, and the enforcement has always been on the
    /// receiving side: a host rejects an oversized command or terminal request, but nothing on
    /// either end refuses to produce one, so a message this size written by mistake is not
    /// refused anywhere near where it was made. The video fallback is the first thing that
    /// routinely has payloads larger than this, which is why it cuts them up rather than
    /// trusting the far end's buffer to be as large as the phone's is.
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
