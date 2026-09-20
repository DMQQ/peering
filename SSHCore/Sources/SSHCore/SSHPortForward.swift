import Foundation

/// Why a forward's details were not accepted.
///
/// Each case carries the sentence the editor shows, for the same reason ``SSHKeyError`` does: the
/// user is looking at three fields they have just typed into, and "invalid" makes them re-read all
/// three. Naming the field is the whole of the help here.
public enum SSHPortForwardError: Error, Sendable, Equatable {
    case localPortNotANumber
    case localPortOutOfRange
    case remotePortNotANumber
    case remotePortOutOfRange
    case remoteHostEmpty
    case remoteHostNotAHostname
    /// Another forward on this server already listens on that port, which cannot work: two
    /// listeners on one port is an address already in use, and the second one to start loses.
    case localPortAlreadyUsed(Int)

    public var message: String {
        switch self {
        case .localPortNotANumber:
            return "The local port has to be a number."
        case .localPortOutOfRange:
            return "The local port has to be between 1 and 65535."
        case .remotePortNotANumber:
            return "The port on the server has to be a number."
        case .remotePortOutOfRange:
            return "The port on the server has to be between 1 and 65535."
        case .remoteHostEmpty:
            return "Say which machine the server should connect to. It is the machine at the far end of the tunnel, and it is the server that does the connecting."
        case .remoteHostNotAHostname:
            return "That is not a hostname or an address. Letters, digits, dots, colons and hyphens only."
        case .localPortAlreadyUsed(let port):
            return "This server already forwards \(port). Two forwards cannot listen on the same port, so one of them would never start."
        }
    }
}

/// One tunnel a saved server carries: a port on this phone, onto something the server can reach.
///
/// ## The direction, because it is the thing users get backwards
///
/// This is OpenSSH's `-L`: the listener is on the *phone* and the connection is made by the
/// *server*. A user pointing at a database behind a firewall writes the database's address and port
/// here, and then points an app on the phone at `localhost:<localPort>`. The server does the
/// connecting, from where it sits, which is the whole reason the tunnel is worth having.
///
/// ## What is not here
///
/// No bind address, and that is a decision rather than an omission. The listener is always on
/// `127.0.0.1`, so only this phone can reach it. A forward bound to `0.0.0.0` would expose whatever
/// is at the far end to every device on the coffee shop's wifi, and it would do it silently, from a
/// switch labelled "port forward" that says nothing about a network. OpenSSH's own default for `-L`
/// is the same, and a user who needs the other one can say so the day the app has a field that
/// explains what it costs.
///
/// No remote-side listener either. That is `-R`, and it needs the server's cooperation in a way
/// this does not, so it is a different feature rather than a second field here.
public struct SSHPortForward: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// What the user calls it. Empty means "say it as the address it is".
    public var label: String
    /// The port on this phone. Everything an app on the phone connects to.
    public var localPort: Int
    /// Where the *server* connects to, which is usually a name that resolves only from there.
    public var remoteHost: String
    public var remotePort: Int
    /// Whether this starts with the shell.
    ///
    /// Stored rather than held in memory, because the answer has to survive the app being closed:
    /// a forward the user turned off that comes back on the next launch is a port they thought was
    /// shut.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        label: String = "",
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.isEnabled = isEnabled
    }

    /// What the row shows first.
    public var displayName: String {
        label.isEmpty ? "\(localPort) → \(remoteHost):\(remotePort)" : label
    }

    /// The line under it, which is always the addresses, whether or not there is a name.
    ///
    /// Both halves are shown, and `localhost` is spelled out rather than left implicit: the one
    /// thing a user has to know to use a forward is what to point their app at, and a row that says
    /// only `web.internal:80` never tells them.
    public var detail: String {
        "localhost:\(localPort) → \(remoteHost):\(remotePort)"
    }

    // MARK: - Reading the editor's three fields

    /// Turns what was typed into a forward, or says which field is wrong.
    ///
    /// Takes the strings rather than the numbers because this runs on every keystroke's worth of
    /// state, and a `Int?` computed by the caller would be a second place that has to decide what
    /// "not a number yet" means. `existing` is the other forwards on the same server, so the
    /// duplicate check can be part of the same answer rather than a second rule the editor has to
    /// remember to apply.
    public static func reading(
        label: String,
        localPort: String,
        remoteHost: String,
        remotePort: String,
        existing: [SSHPortForward] = [],
        ignoring id: UUID? = nil
    ) -> Result<SSHPortForward, SSHPortForwardError> {
        let port = localPort.trimmingCharacters(in: .whitespaces)
        guard let local = port.isEmpty ? nil : Int(port) else {
            return .failure(.localPortNotANumber)
        }
        guard (1...65535).contains(local) else { return .failure(.localPortOutOfRange) }
        guard existing.contains(where: { $0.localPort == local && $0.id != id }) == false else {
            return .failure(.localPortAlreadyUsed(local))
        }

        let remote = remoteHost.trimmingCharacters(in: .whitespaces)
        guard !remote.isEmpty else { return .failure(.remoteHostEmpty) }
        guard isHostname(remote) else { return .failure(.remoteHostNotAHostname) }

        let other = remotePort.trimmingCharacters(in: .whitespaces)
        guard let remoteNumber = other.isEmpty ? nil : Int(other) else {
            return .failure(.remotePortNotANumber)
        }
        guard (1...65535).contains(remoteNumber) else { return .failure(.remotePortOutOfRange) }

        // The id of the forward being edited is kept, so that saving a change does not replace one
        // record with another: the row a user is looking at must not vanish from under them because
        // they changed which port it names.
        return .success(
            SSHPortForward(
                id: id ?? UUID(),
                label: label.trimmingCharacters(in: .whitespaces),
                localPort: local,
                remoteHost: remote,
                remotePort: remoteNumber,
                isEnabled: existing.first { $0.id == id }?.isEnabled ?? true
            )
        )
    }

    /// Whether a string could name a machine.
    ///
    /// Deliberately loose: a hostname is resolved on the *server*, and this app has no way to know
    /// what that server's resolver accepts. What it does reject is the thing a user actually types
    /// by mistake, which is a whole command line copied out of a tutorial, and rejecting that here
    /// turns a handshake that fails silently into a sentence under the field.
    private static func isHostname(_ text: String) -> Bool {
        !text.contains(" ") && text.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "." || character == "-" || character == ":" || character == "_"
        }
    }
}
