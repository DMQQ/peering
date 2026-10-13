import Foundation

/// The two calls a lookup makes on a signalling socket, so a test can stand in for it.
protocol RelayPeerLink: Sendable {
    func send(_ message: RelayClientMessage) async throws
    func receive() async throws -> RelayServerMessage
    func cancel()
}

extension RelaySignallingConnection: RelayPeerLink {}

/// Asks the relay where the other end of a session is, over one signalling socket kept for as long as it works.
///
/// The relay answers each request exactly once, so asking again on the same socket is safe. A socket that fails or times out is closed, and the next ask opens a new one.
public actor RelayPeerLookup {
    private let open: @Sendable () -> any RelayPeerLink
    private var link: (any RelayPeerLink)?
    private(set) var socketsOpened = 0

    init(open: @escaping @Sendable () -> any RelayPeerLink) {
        self.open = open
    }

    public init(url: URL) {
        self.init(open: { RelaySignallingConnection(url: url) })
    }

    /// `nil` means only that the peer has not been heard from yet, which is the ordinary first answer.
    public func address(videoToken: Data) async throws -> RelayPeerAddress? {
        try await address(videoToken: videoToken, deadline: ConnectDeadlines.peerDiscovery)
    }

    func address(videoToken: Data, deadline: TimeInterval) async throws -> RelayPeerAddress? {
        let link = currentLink()
        do {
            return try await Deadline.run(seconds: deadline) {
                try await withTaskCancellationHandler {
                    try await link.send(.requestPeerAddress(videoToken: videoToken))
                    return try await Self.answer(from: link)
                } onCancel: {
                    link.cancel()
                }
            }
        } catch is Deadline.Exceeded {
            close()
            throw RelaySignallingError.timedOut
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        link?.cancel()
        link = nil
    }

    private func currentLink() -> any RelayPeerLink {
        if let link { return link }
        let opened = open()
        link = opened
        socketsOpened += 1
        return opened
    }

    private static func answer(from link: any RelayPeerLink) async throws -> RelayPeerAddress? {
        while true {
            switch try await link.receive() {
            case .peerAddress(let address): return address
            case .error(let code, _) where code == "peerAddressUnknown": return nil
            case .error(let code, let message): throw RelaySignallingError.refused(code: code, message: message)
            case .pong, .registered, .referral, .activityRefused, .hostPresence: continue
            case .sessionReady, .hostOffline: throw RelaySignallingError.unexpectedResponse
            }
        }
    }
}
