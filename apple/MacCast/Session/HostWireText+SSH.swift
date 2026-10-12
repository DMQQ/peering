import Foundation
import MacCastKit
import SSHCore

extension HostWireText {
    /// The closed set of sentences `SSHCore` writes for file service, key, port forward and
    /// forwarder failures. The package keeps English for logs; the app words them at display.
    static func ssh(_ text: String) -> String? {
        sshServer(text) ?? sshFiles(text) ?? sshKeyAndForward(text) ?? sshPatterned(text)
    }

    static func forwardSummary(_ state: SSHForwardState) -> String {
        switch state {
        case .stopped: String(localized: "Stopped")
        case .starting: String(localized: "Starting")
        case .running(let problem): problem.map(localized) ?? String(localized: "Running")
        case .failed(let reason): localized(reason)
        }
    }

    private static func sshServer(_ text: String) -> String? {
        switch text {
        case "The server would not say where it starts.": String(localized: "The server would not say where it starts.")
        case "The server refused to list that folder.": String(localized: "The server refused to list that folder.")
        case "The server would not let this account read that.": String(localized: "The server would not let this account read that.")
        case "The server refused.": String(localized: "The server refused.")
        case "The server did not answer.": String(localized: "The server did not answer.")
        case "This server speaks a version of SFTP this app does not.":
            String(localized: "This server speaks a version of SFTP this app does not.")
        case "The server would not open another channel.": String(localized: "The server would not open another channel.")
        case "The server answered a listing request with a file.": String(localized: "The server answered a listing request with a file.")
        case "The server answered a file request with a folder.": String(localized: "The server answered a file request with a folder.")
        case "The server answered a write with something else.": String(localized: "The server answered a write with something else.")
        case "The server answered a change with something else.": String(localized: "The server answered a change with something else.")
        case "This server's key was not accepted.": String(localized: "This server's key was not accepted.")
        case "This server's key has changed.": String(localized: "This server's key has changed.")
        case "The shell this forward runs on has ended.": String(localized: "The shell this forward runs on has ended.")
        default: nil
        }
    }

    private static func sshFiles(_ text: String) -> String? {
        switch text {
        case "This server does not offer SFTP, so a file cannot be read here.":
            String(localized: "This server does not offer SFTP, so a file cannot be read here.")
        case "This server does not offer SFTP, so a file cannot be saved here.":
            String(localized: "This server does not offer SFTP, so a file cannot be saved here.")
        case "This server does not offer SFTP, so files cannot be changed here.":
            String(localized: "This server does not offer SFTP, so files cannot be changed here.")
        case "That is no longer there.": String(localized: "That is no longer there.")
        case "The folder could not be read.": String(localized: "The folder could not be read.")
        case "That folder has more in it than this app will read at once.":
            String(localized: "That folder has more in it than this app will read at once.")
        case "That is not a name a file can have.": String(localized: "That is not a name a file can have.")
        case "Something with that name is already there.": String(localized: "Something with that name is already there.")
        case "That is too much of the server to delete.": String(localized: "That is too much of the server to delete.")
        case "That file is not text or a picture, so there is nothing to show here.":
            String(localized: "That file is not text or a picture, so there is nothing to show here.")
        case "That is not a file, so there is nothing to show here.":
            String(localized: "That is not a file, so there is nothing to show here.")
        default: nil
        }
    }

    private static func sshKeyAndForward(_ text: String) -> String? {
        switch text {
        case "That is not a private key. A private key starts with -----BEGIN OPENSSH PRIVATE KEY-----. If you pasted a line starting with ssh-ed25519, that is the public half, which goes on the server rather than here.":
            String(localized: "That is not a private key. A private key starts with -----BEGIN OPENSSH PRIVATE KEY-----. If you pasted a line starting with ssh-ed25519, that is the public half, which goes on the server rather than here.")
        case "This key has a passphrase. Type it so the app can unlock the key when it connects.":
            String(localized: "This key has a passphrase. Type it so the app can unlock the key when it connects.")
        case "That passphrase did not unlock this key.": String(localized: "That passphrase did not unlock this key.")
        case "the body is not valid base64": String(localized: "the body is not valid base64")
        case "it ends earlier than its own lengths say": String(localized: "it ends earlier than its own lengths say")
        case "The local port has to be a number.": String(localized: "The local port has to be a number.")
        case "The local port has to be between 1 and 65535.": String(localized: "The local port has to be between 1 and 65535.")
        case "The port on the server has to be a number.": String(localized: "The port on the server has to be a number.")
        case "The port on the server has to be between 1 and 65535.":
            String(localized: "The port on the server has to be between 1 and 65535.")
        case "Say which machine the server should connect to. It is the machine at the far end of the tunnel, and it is the server that does the connecting.":
            String(localized: "Say which machine the server should connect to. It is the machine at the far end of the tunnel, and it is the server that does the connecting.")
        case "That is not a hostname or an address. Letters, digits, dots, colons and hyphens only.":
            String(localized: "That is not a hostname or an address. Letters, digits, dots, colons and hyphens only.")
        default: nil
        }
    }

    private static func sshPatterned(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(in: text, template: "The server refused to list that folder (status %@).") {
            return String(localized: "The server refused to list that folder (status \(found[0])).")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "This server already forwards %@. Two forwards cannot listen on the same port, so one of them would never start."
        ) {
            return String(localized: "This server already forwards \(found[0]). Two forwards cannot listen on the same port, so one of them would never start.")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "That folder has more in it than this app will delete in one go (%@ entries). Delete it on the server instead."
        ) {
            return String(localized: "That folder has more in it than this app will delete in one go (\(found[0]) entries). Delete it on the server instead.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "Could not listen on %@: %@") {
            return String(localized: "Could not listen on \(found[0]): \(found[1])")
        }
        return sshKeyPatterned(text)
    }

    private static func sshKeyPatterned(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(in: text, template: "This key could not be read: %@") {
            return String(localized: "This key could not be read: \(localized(found[0]))")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "This app can sign with ed25519 and RSA keys. A %@ key cannot be used here, so it is better not to save one and find out at the next connection."
        ) {
            return String(localized: "This app can sign with ed25519 and RSA keys. A \(found[0]) key cannot be used here, so it is better not to save one and find out at the next connection.")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "This key was saved with a bcrypt cost of %@, and this app can only open keys at 16 or below. Saving it again with `ssh-keygen -p -a 16` would make it usable."
        ) {
            return String(localized: "This key was saved with a bcrypt cost of \(found[0]), and this app can only open keys at 16 or below. Saving it again with `ssh-keygen -p -a 16` would make it usable.")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "This key is encrypted with %@ and %@, and this app can only open the default OpenSSH format (aes256-ctr with bcrypt). Removing or changing the passphrase with `ssh-keygen -p` would make it usable."
        ) {
            return String(localized: "This key is encrypted with \(found[0]) and \(found[1]), and this app can only open the default OpenSSH format (aes256-ctr with bcrypt). Removing or changing the passphrase with `ssh-keygen -p` would make it usable.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "it holds %@ keys, and only single-key files can be used here") {
            return String(localized: "it holds \(found[0]) keys, and only single-key files can be used here")
        }
        return nil
    }
}
