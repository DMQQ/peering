import Foundation
import RemoteCore

extension HostSession {
    /// Starts the streams when the phone asked for them on a relayed connection, which is the only place the lane can carry them. Run on the connection's own queue, so a frame that arrives on a stream is handled where every other frame is.
    func startStreamsIfAsked() {
        guard clientSupportsStreams, let link = streamLink, streams == nil else { return }

        let transport = StreamTransport(
            queue: connection.queue,
            hooks: StreamTransport.Hooks(
                sendOnControl: { [weak self] payload in self?.connection.send(Frame(kind: .stream, payload: payload)) },
                sendOnLane: { [weak link] payload in link?.sendOnLane(payload) },
                laneIsLive: { [weak link] in link?.laneIsLive == true },
                deliver: { [weak self] frame in self?.handle(frame) },
                fail: { [weak self] error in self?.fail(SessionError.malformedPayload(.stream, error)) }
            )
        )
        streams = transport
        link.setReceiver { [weak transport] payload in transport?.receive(payload) }
        connection.router = { [weak transport] frame in transport?.send(frame) ?? false }
        transport.start()
    }

    func stopStreams() {
        connection.router = nil
        streamLink?.setReceiver(nil)
        streamLink?.detachLane()
        streams?.stop()
        streams = nil
    }
}
