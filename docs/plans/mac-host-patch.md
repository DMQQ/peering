# Mac host patch: platform and codec hints (APPLIED)

Status: applied by the owner in commit a50f539 (`apple/RemoteCore`, `apple/MacCastHost`, and the paragraph in `docs/protocol.md`). The text below is the original proposal; the commit is the source of truth.

For the owner to review and apply. Nothing under `apple/` was changed. Additive only: no change to existing fields, no
`ProtocolInfo.version` bump. Shipped iPhone builds ignore unknown keys, so a host that sends the new fields stays compatible with
them, and a new client talking to an old host simply gets no answer to the hints.

Not built or run. Line numbers were read on 2026-10-11 and will drift.

## 1. New optional fields

`apple/RemoteCore/Sources/RemoteCore/Handshake.swift`

```swift
public struct ClientHello {
    /// "ios", "android". Informational: lets a host adapt shortcuts and warnings. nil reads as unknown.
    public var clientPlatform: String?

    /// Codecs this client can decode in hardware, most preferred first ("hevc", "h264"). nil reads as ["hevc", "h264"],
    /// which is what every shipped iPhone build can do, so an old client keeps today's behaviour.
    public var videoCodecs: [String]?
    // add both to init(...) with default nil, and to the stored properties
}

public struct ServerHello {
    /// "macos", "windows". nil reads as "macos" on the client side.
    public var hostPlatform: String?
    // add to init(...) with default nil
}
```

Both structs use synthesized `Codable`, so a nil optional is omitted and an unknown key from a newer peer is ignored. Add tests to
`HandshakeTests.swift`: a hello without the keys decodes (nil), a hello with them round trips, and the existing literal at
line 179 still decodes.

## 2. Host reads `videoCodecs`

`apple/MacCastHost/Network/HostSession+Handshake.swift`, in `handleClientHello` next to the other `clientSupports...` lines (about line 88):

```swift
clientVideoCodecs = hello.videoCodecs
```

and declare `var clientVideoCodecs: [String]?` on `HostSession`. In the `serverHello` construction (about line 112) add
`hostPlatform: "macos"`.

## 3. Choosing the codec

The encoder is shared by every attached client (`CapturePipeline(resolver:codec:)`, `HostModel+Lifecycle.swift:72`, default HEVC from
`HostModel+Capture.swift:24-26`), so the codec cannot differ per client without a second encoder. Smallest safe rule:

* When a client attaches (`VideoCoordinator` attach path), if its `videoCodecs` is non-nil and does not contain the current codec,
  and no other client is attached, rebuild the encoder with the first codec it lists that the Mac can encode (`VideoEncoder` already
  falls back from HEVC to H.264 when the GPU cannot, `VideoEncoder.swift:190-193`). The session sends a fresh `videoConfig` as for any
  source switch (`AGENTS.md`: switching rebuilds the stream, the client sees no reconnect).
* When another client is attached with an incompatible list, keep the current codec and let the new client see the existing
  behaviour (it will fail to decode, as today). Mixed codec sessions are out of scope.
* Never change a codec while a client that did not send `videoCodecs` is attached.

This keeps iPhone behaviour exactly as it is and lets an Android phone without an HEVC decoder get H.264 from the Mac.

## 4. Test plan

* `apple/RemoteCore` unit tests for the two new optional fields (above).
* A unit test for the codec choice as a pure function in `RemoteCore` or `MacCastKit`:
  `chooseCodec(current:, hostCanEncode:, clientList:, otherClientsAttached:) -> VideoCodec`.
* Manual: connect the Android client with `videoCodecs: ["h264"]` and check the log line `encoder ready ... h264`.
