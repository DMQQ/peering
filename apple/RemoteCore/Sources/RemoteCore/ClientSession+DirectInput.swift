import Foundation

extension ClientSession {
    /// Longer than two pings: a path that has not answered in that time is not trusted with input.
    static let directInputFreshness: TimeInterval = 2.5

    /// Sends a command on the direct datagram path when the route allows it, and says whether the control connection should carry it as well.
    func sendDirectly(_ command: RemoteCommand) -> Bool {
        let now = Self.monotonicNow()
        var path = DirectInputRoute.Path.control
        let sealed: [Data]? = lock.withLock {
            let open = reportedPath == .direct
                && lastPeerDatagramAt.map { now - $0 < Self.directInputFreshness } == true
            let accepts = _serverHello?.supportsDirectInput == true
            path = inputRoute.route(command, now: now, directIsOpen: open, hostAccepts: accepts)
            guard path != .control,
                  videoSealer != nil,
                  let payload = try? MessageCodec.encode(DirectCommand(sequence: directInputSequence, command: command))
            else { return nil }
            directInputSequence &+= 1
            var sealer = videoSealer
            defer { videoSealer = sealer }
            return sealer?.seal(kind: .directCommand, payload: payload)
        }
        guard let sealed, !sealed.isEmpty, let socket = lock.withLock({ videoDatagrams }) else { return false }
        socket.sendDirect(sealed) { _ in }
        return path == .direct
    }
}
