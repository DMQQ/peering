import CryptoKit
import Foundation
import Network
import RemoteCore
import Security
import os

extension HostSession {
    func decode<T: Decodable>(_ type: T.Type, from frame: Frame, as kind: MessageKind) throws -> T {
        do {
            return try MessageCodec.decode(type, from: frame.payload)
        } catch {
            throw SessionError.malformedPayload(kind, error)
        }
    }

    /// Tells the client what stands between it and the picture, or clears what was said.
    ///
    /// Advisory, so it never fails the session: a caption for the frames, not a complaint.
    func sendNotice(_ payload: NoticePayload) {
        guard isAuthorized else { return }
        send(MessageKind.notice, payload)
    }

    func sendTextFocus(_ focus: TextFocus) {
        guard isAuthorized, clientSupportsTextFocus == true else { return }
        send(MessageKind.textFocus, focus)
    }

    func sendFieldState(_ state: FieldState) {
        guard isAuthorized, clientSupportsFieldState == true else { return }
        send(MessageKind.fieldState, state)
    }

    func sendPointer(_ point: NormalizedPoint) {
        guard isAuthorized, clientSupportsPointerReport == true else { return }
        send(MessageKind.pointerReport, point)
    }

    func send<T: Encodable>(_ kind: MessageKind, _ value: T) {
        guard let payload = try? MessageCodec.encode(value) else {
            fail(SessionError.malformedPayload(kind, SessionError.randomFailure))
            return
        }
        connection.send(Frame(kind: kind, payload: payload))
    }

    func fail(_ error: any Error) {
        guard state != .failed else { return }
        state = .failed
        // The Mac's window words it in the Mac's language; the peer is sent the English.
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        emit(.failed(because: error))

        // Cancel only once the explanation has been handed to the transport: cancelling right
        // after `send` discards the queued frame and the peer sees a bare disconnect with no
        // reason, which is exactly when the user most needs to know why it was turned away.
        guard let payload = try? MessageCodec.encode(ErrorPayload(code: "session", message: message)) else {
            connection.cancel()
            return
        }
        connection.send(FrameEncoder.encode(Frame(kind: .error, payload: payload))) { [connection] _ in
            connection.cancel()
        }
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw SessionError.randomFailure
        }
        return Data(bytes)
    }
}
