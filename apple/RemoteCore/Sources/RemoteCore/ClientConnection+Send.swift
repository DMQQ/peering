import Foundation
import Network

extension ClientConnection {
    // MARK: - Send

    /// A payload over ``ProtocolInfo/maxControlPayload`` is dropped here: the Mac treats it as malformed and ends the session, and the resume then replays it.
    public func send(_ frame: Frame) {
        guard let connection else { return }
        guard frame.payload.count <= ProtocolInfo.maxControlPayload else {
            transportLog.error("dropped a \(String(describing: frame.kind), privacy: .public) frame of \(frame.payload.count) bytes, over the control limit")
            return
        }
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    /// Reports once the network stack has taken the frame, or why it could not: the signal a long transfer paces itself on.
    public func send<T: Encodable>(
        _ kind: MessageKind,
        _ value: T,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard let connection else { return completion(Failure.cancelled) }
        do {
            let frame = Frame(kind: kind, payload: try MessageCodec.encode(value))
            connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { completion($0) })
        } catch {
            completion(error)
        }
    }

/// Encodes and sends a command. An encode failure is a programming error, so it is logged, not thrown.
    public func send(_ command: RemoteCommand) {
        do {
            send(Frame(kind: .command, payload: try MessageCodec.encode(command)))
        } catch {
            transportLog.error("could not encode \(String(describing: command), privacy: .public): \(error)")
        }
    }

    public func send<T: Encodable>(_ kind: MessageKind, _ value: T) {
        do {
            send(Frame(kind: kind, payload: try MessageCodec.encode(value)))
        } catch {
            transportLog.error("could not encode a \(String(describing: kind), privacy: .public) payload")
        }
    }
}
