import Foundation
import os

extension ClientSession {
    /// Starts the streams when this client asked for them and the Mac answered that it speaks them too. From here the frame protocol (see ``StreamRouting``) goes out on streams, on the lane while it is live and on the control connection otherwise.
    func startStreamsIfAgreed() {
        let agreed = lock.withLock { streamsAdvertised && _serverHello?.supportsStreams == true && streams == nil }
        guard agreed, let connection = connection() else { return }

        let transport = StreamTransport(
            queue: DispatchQueue(label: "pl.dmq.peering.client.streams"),
            hooks: StreamTransport.Hooks(
                sendOnControl: { [weak connection] payload in connection?.send(Frame(kind: .stream, payload: payload)) },
                sendOnLane: { [weak self] payload in self?.sendStreamDatagram(payload) },
                laneIsLive: { [weak self] in self?.lock.withLock { self?.videoDatagrams }?.pathIsLive == true },
                deliver: { [weak self] frame in self?.handle(frame) },
                fail: { [weak self] _ in
                    self?.fail("The Mac sent something this app cannot read. The two ends may be running different versions.", reason: .other)
                }
            )
        )
        lock.withLock { streams = transport }
        connection.router = { [weak transport] frame, completion in
            transport?.send(frame, completion: completion) ?? false
        }
        transport.start()
    }

    func stopStreams() {
        let (transport, control) = lock.withLock { () -> (StreamTransport?, ClientConnection?) in
            defer { streams = nil }
            return (streams, self.control)
        }
        control?.router = nil
        transport?.stop()
    }

    /// One stream segment, sealed with the lane's key and sent straight to the Mac.
    func sendStreamDatagram(_ payload: Data) {
        let sealed = lock.withLock { () -> [Data] in
            var sealer = videoSealer
            defer { videoSealer = sealer }
            return sealer?.seal(kind: .stream, payload: payload) ?? []
        }
        guard !sealed.isEmpty, let socket = lock.withLock({ videoDatagrams }) else { return }
        socket.sendDirect(sealed) { _ in }
    }
}
