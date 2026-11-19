import Foundation
import PeeringQuicFFI

/// Connection ids and paths: what lets one connection move between the relay, the LAN and a punched address.
extension QuicConnection {
    public enum PathEvent: Sendable, Equatable {
        case validated(local: QuicAddress, peer: QuicAddress)
        case failedValidation(local: QuicAddress, peer: QuicAddress)
        case peerMigrated(local: QuicAddress, peer: QuicAddress)
        case closed(local: QuicAddress, peer: QuicAddress)
    }

    /// Gives the peer spare connection ids, so either end can move to a new path: quiche refuses to probe one without a fresh id (`OutOfIdentifiers`).
    public func issueSpareConnectionIDs(_ count: Int = 2) {
        lock.withLock {
            for _ in 0..<count where quiche_conn_scids_left(connection) > 0 {
                let id = Self.randomConnectionID()
                let resetToken = Self.randomConnectionID()
                var sequence: UInt64 = 0
                id.withUnsafeBytes { idBytes in
                    resetToken.withUnsafeBytes { tokenBytes in
                        _ = quiche_conn_new_scid(
                            connection,
                            idBytes.bindMemory(to: UInt8.self).baseAddress, idBytes.count,
                            tokenBytes.bindMemory(to: UInt8.self).baseAddress, false, &sequence
                        )
                    }
                }
            }
        }
    }

    /// Starts validating another path. False when quiche refuses (no spare id yet, or the path exists).
    @discardableResult
    public func probePath(local: QuicAddress, peer: QuicAddress) -> Bool {
        lock.withLock {
            var sequence: UInt64 = 0
            return local.withSockaddr { localPointer, localLength in
                peer.withSockaddr { peerPointer, peerLength in
                    quiche_conn_probe_path(connection, localPointer, localLength, peerPointer, peerLength, &sequence) == 0
                }
            }
        }
    }

    /// Moves sending to a validated path.
    @discardableResult
    public func migrate(local: QuicAddress, peer: QuicAddress) -> Bool {
        lock.withLock {
            var sequence: UInt64 = 0
            return local.withSockaddr { localPointer, localLength in
                peer.withSockaddr { peerPointer, peerLength in
                    quiche_conn_migrate(connection, localPointer, localLength, peerPointer, peerLength, &sequence) == 0
                }
            }
        }
    }

    public func isPathValidated(local: QuicAddress, peer: QuicAddress) -> Bool {
        lock.withLock {
            local.withSockaddr { localPointer, localLength in
                peer.withSockaddr { peerPointer, peerLength in
                    quiche_conn_is_path_validated(connection, localPointer, Int(localLength), peerPointer, Int(peerLength)) == 1
                }
            }
        }
    }

    /// Path changes since the last call.
    public func pathEvents() -> [PathEvent] {
        lock.withLock {
            var events: [PathEvent] = []
            while let event = quiche_conn_path_event_next(connection) {
                defer { quiche_path_event_free(event) }
                var local = sockaddr_storage(), peer = sockaddr_storage()
                var localLength = socklen_t(0), peerLength = socklen_t(0)
                let make = { (QuicAddress(storage: local, length: localLength), QuicAddress(storage: peer, length: peerLength)) }
                switch quiche_path_event_type(event) {
                case QUICHE_PATH_EVENT_VALIDATED:
                    quiche_path_event_validated(event, &local, &localLength, &peer, &peerLength)
                    let (l, p) = make(); events.append(.validated(local: l, peer: p))
                case QUICHE_PATH_EVENT_FAILED_VALIDATION:
                    quiche_path_event_failed_validation(event, &local, &localLength, &peer, &peerLength)
                    let (l, p) = make(); events.append(.failedValidation(local: l, peer: p))
                case QUICHE_PATH_EVENT_PEER_MIGRATED:
                    quiche_path_event_peer_migrated(event, &local, &localLength, &peer, &peerLength)
                    let (l, p) = make(); events.append(.peerMigrated(local: l, peer: p))
                case QUICHE_PATH_EVENT_CLOSED:
                    quiche_path_event_closed(event, &local, &localLength, &peer, &peerLength)
                    let (l, p) = make(); events.append(.closed(local: l, peer: p))
                default:
                    break
                }
            }
            return events
        }
    }

    /// The largest datagram payload the current path takes, or nil before the peer has said it accepts datagrams.
    public var maxDatagramPayload: Int? {
        let length = lock.withLock { quiche_conn_dgram_max_writable_len(connection) }
        return length > 0 ? length : nil
    }
}
