import Citadel
import Crypto
import Foundation

/// Every case carries the sentence the editor shows: a public key pasted for a private one, and a passphrase-protected key, are what a generic "invalid key" would send users hunting for.
public enum SSHKeyError: Error, Sendable, Equatable {
    /// Not a private key block at all; the likeliest cause is pasting the public half.
    case notAPrivateKey
    case malformed(String)
    /// Citadel has no ECDSA signing, so a pasted `ecdsa-sha2-nistp256` key has no way in however well-formed.
    case unsupportedAlgorithm(String)
    /// Encrypted with a cipher other than the two Citadel implements, or a bcrypt cost it refuses.
    case unsupportedFormat(String)
    case passphraseNeeded
    case passphraseWrong

    public var message: String {
        switch self {
        case .notAPrivateKey:
            return "That is not a private key. A private key starts with -----BEGIN OPENSSH PRIVATE KEY-----. If you pasted a line starting with ssh-ed25519, that is the public half, which goes on the server rather than here."
        case .malformed(let reason):
            return "This key could not be read: \(reason)"
        case .unsupportedAlgorithm(let name):
            return "This app can sign with ed25519 and RSA keys. A \(name) key cannot be used here, so it is better not to save one and find out at the next connection."
        case .unsupportedFormat(let detail):
            return detail
        case .passphraseNeeded:
            return "This key has a passphrase. Type it so the app can unlock the key when it connects."
        case .passphraseWrong:
            return "That passphrase did not unlock this key."
        }
    }
}

/// A private key and its public half. The public line is derived once, at creation or import, from the private key's own text (OpenSSH embeds the identical wire blob a server compares against `authorized_keys`), so a screen never parses keys and a new key type cannot drift into "permission denied (publickey)".
/// Passphrases are stored beside the key in the same Keychain blob (a phone has no ssh-agent), never in the host list.
/// Citadel implements two ciphers, `aes128-ctr` and `aes256-ctr`, and bcrypt below 32 rounds (`OpenSSH.KDF.init(consuming:)`). `ssh-keygen`'s default (`aes256-ctr`, 16 rounds) works; `-Z aes256-gcm@openssh.com` and `-a 40` do not, and are refused at paste time rather than failing mid-handshake.
public struct SSHKeyPair: Codable, Sendable, Equatable {
    public let privateKey: String
    public let publicKey: String
    public let passphrase: String?

    public var algorithm: String {
        publicKey.split(separator: " ").first.map(String.init) ?? "unknown"
    }

    public var comment: String {
        let parts = publicKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count > 2 else { return "" }
        return String(parts[2])
    }

    /// Rebuilt from the blob rather than by string surgery, so a comment containing the separator or an empty one still parses back.
    public func labelled(_ comment: String) -> SSHKeyPair {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBlob = publicKey.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let line = trimmed.isEmpty
            ? "\(algorithm) \(trimmedBlob)"
            : "\(algorithm) \(trimmedBlob) \(trimmed)"
        return SSHKeyPair(privateKey: privateKey, publicKey: line, passphrase: passphrase)
    }

    private init(privateKey: String, publicKey: String, passphrase: String?) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.passphrase = passphrase
    }

    // MARK: - Making one

    /// ed25519 (OpenSSH's default since 8.5), written with no passphrase: the private half never leaves the Keychain, so a passphrase would be a second lock on a locked door.
    public static func generate(comment: String = "") throws -> SSHKeyPair {
        let key = Curve25519.Signing.PrivateKey()
        let text = key.makeSSHRepresentation(comment: comment)
        // Read back so generated and imported keys share one path for building the public line.
        let blob = try Self.readHeader(text)
        return SSHKeyPair(
            privateKey: text,
            publicKey: Self.line(algorithm: blob.algorithm, blob: blob.publicKey, comment: comment),
            passphrase: nil
        )
    }

    /// Throws rather than accepting what it cannot prove: this is the one moment a passphrase can be checked, and later the failure would arrive as a transport error.
    public static func imported(_ text: String, passphrase: String?) throws -> SSHKeyPair {
        let header = try readHeader(text)
        let trimmedPassphrase = passphrase.flatMap { phrase in
            phrase.isEmpty ? nil : phrase
        }

        // A passphrase typed against an unencrypted key is dropped: the library ignores it, so keeping it would hold a secret for no reason.
        guard header.isEncrypted else {
            return SSHKeyPair(
                privateKey: text,
                publicKey: line(algorithm: header.algorithm, blob: header.publicKey, comment: header.comment),
                passphrase: nil
            )
        }

        guard let trimmedPassphrase else { throw SSHKeyError.passphraseNeeded }
        do {
            try key(from: text, algorithm: header.algorithm, passphrase: trimmedPassphrase)
        } catch {
            throw SSHKeyError.passphraseWrong
        }

        return SSHKeyPair(
            privateKey: text,
            publicKey: line(algorithm: header.algorithm, blob: header.publicKey, comment: header.comment),
            passphrase: trimmedPassphrase
        )
    }

    // MARK: - Using one

    /// In practice the throw is unreachable: ``imported(_:passphrase:)`` already refuses everything this does, short of a stored blob edited by something else.
    func authenticationMethod(username: String) throws -> SSHAuthenticationMethod {
        let decryptionKey = passphrase.map { Data($0.utf8) }
        return try Self.method(username: username, text: privateKey, algorithm: algorithm, decryptionKey: decryptionKey)
    }

    private static func method(
        username: String,
        text: String,
        algorithm: String,
        decryptionKey: Data?
    ) throws -> SSHAuthenticationMethod {
        switch algorithm {
        case "ssh-ed25519":
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey)
            return .ed25519(username: username, privateKey: key)
        case "ssh-rsa":
            let key = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey)
            return .rsa(username: username, privateKey: key)
        default:
            throw SSHKeyError.unsupportedAlgorithm(algorithm)
        }
    }

    private static func key(from text: String, algorithm: String, passphrase: String) throws {
        _ = try method(
            username: "",
            text: text,
            algorithm: algorithm,
            decryptionKey: Data(passphrase.utf8)
        )
    }

    // MARK: - Reading an OpenSSH private key

    /// Read here rather than through Citadel's internal parser, which returns only the key: the cipher and KDF cost decide whether the library can open the file, and a failed attempt cannot tell a wrong passphrase from an unsupported format.
    private struct Header {
        let algorithm: String
        let publicKey: [UInt8]
        let comment: String
        let isEncrypted: Bool
    }

    private static func readHeader(_ text: String) throws -> Header {
        let bytes = try body(of: text)
        var reader = SSHRawReader(bytes)

        // The magic (`openssh-key-v1` and a zero) is not length-prefixed; reading it as an SSH string runs off the end of any key.
        let magic = Array("openssh-key-v1".utf8)
        guard try reader.readBytes(magic.count) == magic, try reader.readByte() == 0
        else { throw SSHKeyError.notAPrivateKey }

        let cipher = try String(decoding: reader.readString(), as: UTF8.self)
        let kdf = try String(decoding: reader.readString(), as: UTF8.self)
        let kdfOptions = try reader.readString()

        switch (cipher, kdf) {
        case ("none", "none"):
            break
        case ("aes128-ctr", "bcrypt"), ("aes256-ctr", "bcrypt"):
            // Citadel rejects the cost before any decryption, so a high-cost key would fail the handshake with a transport message unless stopped here.
            var options = SSHRawReader(kdfOptions)
            _ = try options.readString()
            let rounds = try options.readUInt32()
            guard rounds < 32 else {
                throw SSHKeyError.unsupportedFormat(
                    "This key was saved with a bcrypt cost of \(rounds), and this app can only open keys at 16 or below. Saving it again with `ssh-keygen -p -a 16` would make it usable."
                )
            }
        default:
            throw SSHKeyError.unsupportedFormat(
                "This key is encrypted with \(cipher) and \(kdf), and this app can only open the default OpenSSH format (aes256-ctr with bcrypt). Removing or changing the passphrase with `ssh-keygen -p` would make it usable."
            )
        }

        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw SSHKeyError.malformed("it holds \(keyCount) keys, and only single-key files can be used here")
        }

        let publicKey = try reader.readString()
        var inner = SSHRawReader(publicKey)
        let algorithm = try String(decoding: inner.readString(), as: UTF8.self)
        guard algorithm != "ssh-dss" else {
            throw SSHKeyError.unsupportedAlgorithm(algorithm)
        }
        guard !algorithm.hasPrefix("ecdsa-") else {
            throw SSHKeyError.unsupportedAlgorithm(algorithm)
        }
        guard algorithm == "ssh-ed25519" || algorithm == "ssh-rsa" else {
            throw SSHKeyError.unsupportedAlgorithm(algorithm)
        }

        // The comment lives in the private section, which costs a decryption; left empty for an encrypted key rather than decrypting twice.
        let comment = cipher == "none" ? (try plaintextComment(reader)) : ""

        return Header(
            algorithm: algorithm,
            publicKey: publicKey,
            comment: comment,
            isEncrypted: cipher != "none"
        )
    }

    private static func body(of text: String) throws -> [UInt8] {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let start = text.range(of: begin), let finish = text.range(of: end),
              start.upperBound <= finish.lowerBound
        else { throw SSHKeyError.notAPrivateKey }

        let payload = text[start.upperBound..<finish.lowerBound]
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(payload)) else {
            throw SSHKeyError.malformed("the body is not valid base64")
        }
        return Array(data)
    }

    private static func plaintextComment(_ reader: SSHRawReader) throws -> String {
        var reader = reader
        guard let section = try? reader.readString() else { return "" }
        var inner = SSHRawReader(section)

        // Two check integers, skipped as a pair: skipping one shifts every later field by four bytes and silently blanks the comment.
        guard (try? inner.readUInt32()) != nil, (try? inner.readUInt32()) != nil,
              let keyType = try? String(decoding: inner.readString(), as: UTF8.self)
        else { return "" }

        switch keyType {
        case "ssh-ed25519":
            _ = try? inner.readString()
            _ = try? inner.readString()
        case "ssh-rsa":
            for _ in 0..<6 { _ = try? inner.readString() }
        default:
            return ""
        }

        return (try? String(decoding: inner.readString(), as: UTF8.self)) ?? ""
    }

    private static func line(algorithm: String, blob: [UInt8], comment: String) -> String {
        let encoded = Data(blob).base64EncodedString()
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "\(algorithm) \(encoded)"
            : "\(algorithm) \(encoded) \(trimmed)"
    }
}

/// `uint32 length` then that many bytes; every read past the end throws rather than trapping, with bounds checked before slicing.
private struct SSHRawReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else {
            throw SSHKeyError.malformed("it ends earlier than its own lengths say")
        }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw SSHKeyError.malformed("it ends earlier than its own lengths say")
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else {
            throw SSHKeyError.malformed("it ends earlier than its own lengths say")
        }
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    mutating func readString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard length >= 0, offset + length <= bytes.count else {
            throw SSHKeyError.malformed("it ends earlier than its own lengths say")
        }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }
}
