import Foundation

/// Where a host is: the part that identifies it on a network, and the part that names the account.
///
/// Kept apart from ``SSHHost`` because it is what the *protocol* needs — every connection, every
/// known-hosts lookup and every SFTP path starts from these two fields — while the rest of a saved
/// host is what the *list* needs. A host that has never been saved still has an endpoint.
public struct SSHEndpoint: Hashable, Codable, Sendable {
    public var hostname: String
    public var port: Int

    public init(hostname: String, port: Int = 22) {
        self.hostname = hostname
        self.port = port
    }

    /// The key a known-hosts entry is filed under.
    ///
    /// Lowercased because hostnames are case-insensitive, and `Host.Example.com` arriving once by
    /// hand and once from a paste is one host, not two — and two entries would mean two prompts,
    /// the second of which the user would learn to dismiss.
    ///
    /// The port is always present, even at 22, because a host reached on two ports is two servers
    /// with two keys, and one entry covering both is how a fingerprint check silently stops
    /// meaning anything.
    public var key: String {
        "\(hostname.lowercased()):\(port)"
    }

    public var display: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }
}

/// A machine the user has saved.
///
/// Everything here is *not* a secret: it is an inventory of servers, which is sensitive in the way
/// a list of bookmarks is, and it lives in `UserDefaults` for the same reason the app's terminal
/// history does. The password is not here — see ``SSHCredential`` — and neither is the passcode a
/// lock asks for, which is in ``SSHPasscodeStore``.
public struct SSHHost: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// What the user calls it. Empty means "call it by its hostname", which is the common case and
    /// not worth a field they have to fill in.
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var createdAt: Date
    public var lastConnectedAt: Date?
    /// What this server asks for before it will open.
    public var lock: SSHHostLock
    /// The tunnels this server carries, as a list of what to set up when a shell opens on it.
    ///
    /// On the host rather than in a store of its own, and that is a decision about what a forward
    /// *is*: nobody wants a tunnel to a machine they have not saved. It is also not a secret — a
    /// port number and an address are the same kind of thing as the hostname two fields up — so it
    /// belongs in `UserDefaults` with the rest of the inventory rather than in the keychain.
    ///
    /// The list is the *intent*; whether any of it is up is runtime state that lives nowhere near
    /// here, because a forward only exists while a connection does.
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

    /// Written out by hand for one field, and this is the only reason.
    ///
    /// A property default is not a decoding default: the compiler's synthesized `init(from:)` looks
    /// for every key and throws when one is absent, so adding `lock` without this would make the
    /// first run after an update fail to decode *every* server the user had saved — and
    /// ``SSHHostStore/load()`` answers a failed decode with an empty list, so what the user would
    /// see is a Servers tab that has lost all of them.
    ///
    /// **Any field added to this type from now on has to be added here too**, as a
    /// `decodeIfPresent` with the same default as the initializer above.
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

    /// What the row is called.
    public var displayName: String {
        name.isEmpty ? hostname : name
    }

    /// The monospaced second line: `user@host`, with the port only when it is not the default.
    ///
    /// The port is left off at 22 for the same reason a URL leaves off 443 — showing the default
    /// in every row is a number the eye has to skip past to find the ones that differ.
    public var detail: String {
        "\(username)@\(endpoint.display)"
    }
}
