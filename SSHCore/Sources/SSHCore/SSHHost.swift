import Foundation

/// What the protocol needs (every connection, known-hosts lookup and SFTP path starts here); a host that was never saved still has one.
public struct SSHEndpoint: Hashable, Codable, Sendable {
    public var hostname: String
    public var port: Int

    public init(hostname: String, port: Int = 22) {
        self.hostname = hostname
        self.port = port
    }

    /// Lowercased because hostnames are case-insensitive. The port is always present, since a host on two ports is two servers with two keys.
    public var key: String {
        "\(hostname.lowercased()):\(port)"
    }

    public var display: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }
}

/// A machine the user has saved. Not a secret, so it lives in `UserDefaults`; the password is in ``SSHCredential`` and the lock passcode in ``SSHPasscodeStore``.
public struct SSHHost: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var lock: SSHHostLock
    /// On the host rather than in its own store: nobody wants a tunnel to an unsaved machine. This is intent only; whether a forward is up is runtime state.
    public var forwards: [SSHPortForward]

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String,
        port: Int = 22,
        username: String,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        lock: SSHHostLock = .off,
        forwards: [SSHPortForward] = []
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.lock = lock
        self.forwards = forwards
    }

    /// Written by hand because a property default is not a decoding default: without it, adding `lock` made every saved server fail to decode and ``SSHHostStore/load()`` answered with an empty list.
    /// Any field added to this type must be added here too, as a `decodeIfPresent` with the same default as the initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        lock = try container.decodeIfPresent(SSHHostLock.self, forKey: .lock) ?? .off
        forwards = try container.decodeIfPresent([SSHPortForward].self, forKey: .forwards) ?? []
    }

    public var endpoint: SSHEndpoint {
        SSHEndpoint(hostname: hostname, port: port)
    }

    public var displayName: String {
        name.isEmpty ? hostname : name
    }

    /// `user@host`, with the port only when it is not the default.
    public var detail: String {
        "\(username)@\(endpoint.display)"
    }
}
