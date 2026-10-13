import Foundation
import Network

extension ClientConnection {
    public enum Failure: LocalizedError, Sendable, Equatable {
        case invalidPort(UInt16)
        case timedOut(TimeInterval)
        case cancelled
        case hostClosed
        case refused(String)
        case transport(String)
        case network(NetworkFailureText.Kind)
        /// The byte stream could not be framed.
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "\(port) is not a usable TCP port."
            case .timedOut(let seconds):
                return "Timed out after \(Int(seconds))s waiting for the Mac to answer."
            case .cancelled:
                return "Connection cancelled."
            case .hostClosed:
                return "The Mac closed the connection."
            case .refused(let message):
                return "The Mac refused the session: \(message)"
            case .transport(let message), .malformed(let message):
                return message
            case .network(let kind):
                return NetworkFailureText.sentence(for: kind)
            }
        }

        /// A network error keeps its kind, so the app can word it; anything else keeps the sentence it already has.
        static func transport(from error: Error) -> Failure {
            if let network = error as? NWError { return .network(NetworkFailureText.kind(of: network)) }
            if error is FramingError { return .malformed(NetworkFailureText.describe(error)) }
            return .transport(NetworkFailureText.describe(error))
        }
    }
}
