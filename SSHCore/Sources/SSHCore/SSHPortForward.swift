import Foundation

/// Each case carries the sentence the editor shows, naming the field at fault.
public enum SSHPortForwardError: Error, Sendable, Equatable {
    case localPortNotANumber
    case localPortOutOfRange
    case remotePortNotANumber
    case remotePortOutOfRange
    case remoteHostEmpty
    case remoteHostNotAHostname
    /// Another forward on this server already listens on that port; the second to start would lose.
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

///
/// This is OpenSSH's `-L`: the listener is on the *phone* and the connection is made by the *server*.
/// No bind address: the listener is always on `127.0.0.1`, since `0.0.0.0` would silently expose the far end to every device on the network. No remote-side listener (`-R`) either: that needs the server's cooperation.
public struct SSHPortForward: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var label: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    /// Stored because the answer must survive the app closing: a forward the user turned off must not come back on.
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

    public var displayName: String {
        label.isEmpty ? "\(localPort) → \(remoteHost):\(remotePort)" : label
    }

    /// The addresses, with `localhost` spelled out: the user needs to know what to point their app at.
    public var detail: String {
        "localhost:\(localPort) → \(remoteHost):\(remotePort)"
    }

    // MARK: - Reading the editor's three fields

    /// Takes strings because this runs per keystroke and the caller should not decide what "not a number yet" means. `existing` makes the duplicate check part of the same answer.
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

        // The id is kept so saving a change does not make the row vanish.
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

    /// Deliberately loose: the hostname is resolved on the server. It rejects a whole command line pasted from a tutorial.
    private static func isHostname(_ text: String) -> Bool {
        !text.contains(" ") && text.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "." || character == "-" || character == ":" || character == "_"
        }
    }
}
