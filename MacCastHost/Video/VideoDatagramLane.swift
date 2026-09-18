import Foundation
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// The relay's datagram path, as the video pipeline sees it: a socket to send on, and the
/// sealing that makes what goes out unreadable to the relay in the middle.
///
/// It exists as its own type because ``VideoStreamer`` has to treat it as a destination
/// without knowing anything about sockets, counters or ciphertext — the streamer decides
/// *which* lane a frame goes on, and everything about *how* it goes on that lane lives here.
///
/// The relay allocates the address and the token; the secret is this Mac's, generated when the
/// client asked for the lane and sent to it inside the control channel's TLS session. The
/// relay forwards the datagrams and cannot read one of them.
final class VideoDatagramLane: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: VideoDatagramSocket
    private var sealer: VideoDatagramSealer

    /// - Throws: when the relay's allocation cannot be used — a token that is not the size the
    ///   wire contract fixes it at, or a port that is not a port. The caller refuses the
    ///   request rather than reporting a lane that cannot carry anything.
    init(relay: RelaySession, secret: Data) throws {
        socket = try VideoDatagramSocket(
            host: relay.videoHost,
            port: relay.videoPort,
            token: relay.videoToken,
            label: "pl.dmq.peering.host.video.datagrams"
        )
        sealer = try VideoKeySchedule(secret: secret).sealer(
            token: relay.videoToken,
            direction: .hostToClient
        )
    }

    /// Opens the socket and binds, so the relay knows where this Mac's datagrams come from
    /// before the first of them is sent. See ``VideoDatagramSocket/start()``.
    func start() {
        socket.onFailure = { error in
            videoLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
        }
        socket.start()
    }

    func cancel() {
        socket.cancel()
    }

    var sentDatagrams: Int { socket.sentDatagrams }

    /// The datagrams one payload becomes, sealed and ready to send.
    ///
    /// Called with the streamer's lock held, which is what keeps the chunk numbering of one
    /// frame from being handed to another.
    func seal(kind: MessageKind, payload: Data) -> [Data] {
        lock.withLock { sealer.seal(kind: kind, payload: payload) }
    }

    /// Sends a group of datagrams and reports when the last one is away. The completion is the
    /// streamer's flow control, exactly as it is for a write to a connection.
    func send(_ datagrams: [Data], completion: @escaping @Sendable (Error?) -> Void) {
        socket.send(datagrams, completion: completion)
    }
}
