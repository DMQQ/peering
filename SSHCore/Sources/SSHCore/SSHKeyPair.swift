import Citadel
import Crypto
import Foundation

/// Why a pasted or imported key was not accepted.
///
/// Every case carries the sentence the editor shows, because the two failures a user will actually
/// hit — "this is a public key, not a private one" and "this key has a passphrase" — are the two a
/// generic "invalid key" would send them hunting for. Both are answerable with one line about the
/// thing they pasted.
public enum SSHKeyError: Error, Sendable, Equatable {
    /// The text is not a `-----BEGIN OPENSSH PRIVATE KEY-----` block at all.
    ///
    /// The likeliest way to land here is pasting the *public* half, which is the line the server
    /// wants and not the one this screen does — so the message says that rather than "invalid".
    case notAPrivateKey
    /// It is an OpenSSH private key, and its bytes could not be read.
    case malformed(String)
    /// Readable, but an algorithm this app cannot sign with. Citadel has no ECDSA signing support,
    /// so a pasted `ecdsa-sha2-nistp256` key is a key with no way in however well-formed it is.
    case unsupportedAlgorithm(String)
    /// Encrypted in a way the library cannot undo: a cipher other than the two it implements, or a
    /// bcrypt cost it refuses. See ``SSHKeyPair`` for the measured account of the bounds.
    case unsupportedFormat(String)
    /// Encrypted, and no passphrase was given.
    case passphraseNeeded
    /// Encrypted, a passphrase was given, and the key did not decrypt with it.
    case passphraseWrong

    /// What the editor puts under the field the key was pasted into.
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

/// A private key and its public half, in the two forms that leave this type.
///
/// ## Why the whole pair is one value
///
/// The private half is useless without the public half being somewhere the server will accept, and
/// a user who cannot get at the public half has a key they cannot install — which makes the whole
/// feature a dead end that looks like it works. So the public line is derived once, at the moment
/// the key is made or imported, and carried beside the private half for the rest of its life. The
/// alternative, deriving it on demand from the private bytes, means the screen that shows it has to
/// know how to parse a key, and a screen that parses is a screen that can disagree with the
/// handshake.
///
/// ## Where the public half comes from
///
/// Out of the private key's own text, not out of the swift-crypto key that gets built from it.
/// OpenSSH's private key format embeds the public key as the identical wire blob a server compares
/// against `authorized_keys`, so reading that blob means the line the user copies is byte-for-byte
/// what the server already has. Building it instead from a `Curve25519.Signing.PublicKey` would be
/// the same 32 bytes today and a different blob the day somebody adds a key type that prefixes
/// itself, which is exactly the sort of drift that shows up as "permission denied (publickey)" with
/// nothing anywhere to say why.
///
/// ## Passphrases
///
/// Supported, and stored beside the key rather than asked for at each connection: a phone has no
/// ssh-agent, so a key that needs a passphrase typed into a terminal that does not exist yet is a
/// key that cannot be used at all. The passphrase goes in the same Keychain blob as the key,
/// under the same `AfterFirstUnlockThisDeviceOnly` rules, and never into the host list.
///
/// What the library can actually open is narrower than what `ssh-keygen` can write, and it was
/// measured rather than assumed. Citadel implements two ciphers, `aes128-ctr` and `aes256-ctr`
/// (`OpenSSH.Cipher`), and one KDF, bcrypt, whose cost it rejects at 32 rounds or more
/// (`OpenSSH.KDF.init(consuming:)`). `ssh-keygen`'s own default for `-N` is `aes256-ctr` with 16
/// rounds, so the ordinary case works; `ssh-keygen -Z aes256-gcm@openssh.com` and `-a 40` do not.
/// Both are refused at the point the key is pasted, naming the cipher or the cost, because the
/// alternative is a key that appears to save and then fails during a handshake with a message
/// about the transport.
public struct SSHKeyPair: Codable, Sendable, Equatable {
    /// The OpenSSH private key text, header and footer included, exactly as the library is handed it.
    public let privateKey: String
    /// The `ssh-ed25519 AAAA… comment` line the user pastes into the server's `authorized_keys`.
    public let publicKey: String
    /// What the private half is encrypted with, or nil for a key with none. Never in the host store —
    /// see ``SSHCredentialStore`` for where this value lives as a whole.
    public let passphrase: String?

    /// The algorithm as the server names it, read off the public line.
    public var algorithm: String {
        publicKey.split(separator: " ").first.map(String.init) ?? "unknown"
    }

    /// Everything after the base64 on the public line, which is what `authorized_keys` shows beside
    /// the key so a human can tell one entry from another.
    public var comment: String {
        let parts = publicKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count > 2 else { return "" }
        return String(parts[2])
    }

    /// The same key, labelled with a different comment.
    ///
    /// Not a mutation of `publicKey` by string surgery: the line is rebuilt from the blob, so a
    /// comment containing the separator, or an empty one, produces a line that parses back to what
    /// it was meant to be rather than one that has lost a field.
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

    /// A brand new ed25519 key, made on this phone.
    ///
    /// ed25519 rather than RSA because there is nothing here that needs RSA: it is the format
    /// OpenSSH has defaulted to since 8.5, the key is 32 bytes rather than a few thousand, and
    /// signing with it costs no measurable part of a connection. A server that will not take one is
    /// a server that has been configured off the default on purpose, and its owner can paste a key
    /// of their own.
    ///
    /// The key is written out with no passphrase, which is a real decision rather than an omission.
    /// The private half never leaves the Keychain, so a passphrase would be a second lock on a door
    /// that is already locked, bought with a field the user has to fill in and remember, and paid
    /// for on every connection. A key that arrived from somewhere else keeps whatever passphrase it
    /// had; this is only about the one this app makes.
    public static func generate(comment: String = "") throws -> SSHKeyPair {
        let key = Curve25519.Signing.PrivateKey()
        let text = key.makeSSHRepresentation(comment: comment)
        // Read back rather than assembled here: one code path builds the public line for generated
        // and imported keys alike, so the two can never disagree about what a public line is.
        let blob = try Self.readHeader(text)
        return SSHKeyPair(
            privateKey: text,
            publicKey: Self.line(algorithm: blob.algorithm, blob: blob.publicKey, comment: comment),
            passphrase: nil
        )
    }

    /// A key the user pasted or picked from a file.
    ///
    /// Throws rather than accepting anything it cannot prove: this is the one moment the passphrase
    /// can be checked, and finding out at the point of typing beats finding out at the next
    /// connection, when the failure arrives as a transport error with no mention of a key.
    public static func imported(_ text: String, passphrase: String?) throws -> SSHKeyPair {
        let header = try readHeader(text)
        let trimmedPassphrase = passphrase.flatMap { phrase in
            phrase.isEmpty ? nil : phrase
        }

        // A passphrase typed against a key that has none is dropped rather than stored: the library
        // ignores a decryption key for an unencrypted file, so keeping one would be a secret held
        // for no reason, and one that looks like it is doing something it is not.
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

    /// The authentication method this key offers, or a reason it cannot offer one.
    ///
    /// Reached on the connection, so the throw here is a handshake that never starts rather than one
    /// that fails halfway. In practice it is unreachable: everything it refuses was already refused
    /// by ``imported(_:passphrase:)``, and the case that guards is a stored blob edited by something
    /// other than this app.
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

    /// Builds the key without keeping it, for the one caller that wants to know whether a passphrase
    /// is right and nothing else.
    private static func key(from text: String, algorithm: String, passphrase: String) throws {
        _ = try method(
            username: "",
            text: text,
            algorithm: algorithm,
            decryptionKey: Data(passphrase.utf8)
        )
    }

    // MARK: - Reading an OpenSSH private key

    /// The four things this app needs out of a private key's outer structure.
    ///
    /// Read here rather than through Citadel's own parser because that one is internal *and* because
    /// it hands back only the key: the cipher and the KDF cost are what decide whether the library
    /// can open the file at all, and a caller that learns that by trying has to tell a passphrase
    /// that is wrong from a format that is unsupported by looking at one generic error.
    private struct Header {
        let algorithm: String
        let publicKey: [UInt8]
        let comment: String
        let isEncrypted: Bool
    }

    private static func readHeader(_ text: String) throws -> Header {
        let bytes = try body(of: text)
        var reader = SSHRawReader(bytes)

        // The magic is the one field in the file that is not length-prefixed: the literal bytes of
        // `openssh-key-v1` and a zero. Reading it as an SSH string, the way every other field here
        // is read, takes the first four bytes of "open" as a length and runs off the end of any key
        // at all, which is why the count is spelled out rather than guessed at.
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
            // Citadel's KDF parser rejects a cost it will not run, and does it before any decryption
            // is attempted — so a key at or above that cost fails the handshake with a message about
            // the transport unless it is stopped here, where the sentence can name the number.
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

        // The outer public key: exactly the blob a server compares an offer against.
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

        // The private section is where the comment lives, and reading it costs a decryption that
        // has to be done anyway to check a passphrase. Left empty when the key is encrypted: the
        // comment there is the user's own label, and losing it is not worth decrypting twice.
        let comment = cipher == "none" ? (try plaintextComment(reader)) : ""

        return Header(
            algorithm: algorithm,
            publicKey: publicKey,
            comment: comment,
            isEncrypted: cipher != "none"
        )
    }

    /// Strips the PEM wrapper and decodes the body.
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

    /// The comment out of the unencrypted private section, which sits after the key material.
    private static func plaintextComment(_ reader: SSHRawReader) throws -> String {
        var reader = reader
        guard let section = try? reader.readString() else { return "" }
        var inner = SSHRawReader(section)

        // Two check integers that have to be equal to each other, and are the thing the library
        // actually verifies a passphrase with. Skipped rather than compared, and skipped as a
        // *pair*: reading one and moving on shifts every field after it by four bytes, which reads
        // as a key whose comment is silently blank rather than as an error anywhere.
        guard (try? inner.readUInt32()) != nil, (try? inner.readUInt32()) != nil,
              let keyType = try? String(decoding: inner.readString(), as: UTF8.self)
        else { return "" }

        // Past the key material, which is one field per structure rather than a parse of it: the
        // public half, then the private half, and nothing in either has to be understood to be
        // stepped over.
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

/// A cursor over the bytes of an OpenSSH structure.
///
/// The whole of the format is `uint32 length` followed by that many bytes, so a reader that knows
/// one rule can walk any part of it, and every read that runs off the end throws rather than
/// trapping. Bounds are checked against `count` before the slice is taken, so a length field the
/// source file lied about is an error and not a crash.
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
