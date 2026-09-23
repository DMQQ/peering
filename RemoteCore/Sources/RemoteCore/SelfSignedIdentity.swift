import Foundation
import Security
import SwiftASN1
import X509

/// A long-term TLS identity: a keychain-backed P-256 key with a self-signed certificate minted over
/// it at launch. Used by both the host and the client.
///
/// The private key never leaves the keychain: `Certificate.PrivateKey(secKey)` signs through
/// `SecKeyCreateSignature` rather than exporting the key material, and the key is eligible for
/// Secure Enclave backing.
///
/// The certificate is regenerated on every launch, on purpose: peers pin the public key, not the
/// certificate, so a fresh serial number and validity window change nothing.
///
/// `kSecAttrIsPermanent: true` is load-bearing: `SecIdentityCreate` returns nil for a key that is not
/// keychain-backed.
public final class SelfSignedIdentity: @unchecked Sendable {
    /// Which side of the connection this identity represents: the two roles differ only in the
    /// keychain tag and the extended key usage, so a machine running both keeps two distinct keys.
    public enum Role: Sendable {
        case server
        case client

        var keyTag: Data {
            switch self {
            case .server: Data("pl.dmq.peering.host.identity".utf8)
            case .client: Data("pl.dmq.peering.client.identity".utf8)
            }
        }

        var extendedKeyUsage: ExtendedKeyUsage {
            get throws {
                switch self {
                case .server: try ExtendedKeyUsage([.serverAuth])
                case .client: try ExtendedKeyUsage([.clientAuth])
                }
            }
        }
    }

    public let secIdentity: SecIdentity
    public let certificateDER: Data

    /// Canonical public-key bytes: the 65-byte uncompressed P-256 point, `0x04 ‖ X ‖ Y`.
    ///
    /// This is the pin value, byte-identical to what `SecKeyCopyExternalRepresentation` returns, which
    /// lets either side verify a pin with no ASN.1 library.
    public let publicKeyBytes: Data

    /// The subject common name, shown in the peer's device list.
    public let commonName: String

    public enum Failure: LocalizedError {
        case keyGeneration(String)
        case keychain(OSStatus)
        case certificateBuild(String)
        case certificateSerialization(String)
        case certificateRejected
        case identityCreationFailed
        case identityNotRemoved
        case signing(String)

        public var errorDescription: String? {
            switch self {
            case .keyGeneration(let detail):
                return "Could not generate the identity key: \(detail)"
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            case .certificateBuild(let detail):
                return "Could not build the self-signed certificate: \(detail)"
            case .certificateSerialization(let detail):
                return "Could not serialise the certificate: \(detail)"
            case .certificateRejected:
                return "Security framework rejected the generated certificate."
            case .identityCreationFailed:
                return "SecIdentityCreate failed. The key may not be keychain-backed."
            case .identityNotRemoved:
                return "The identity key could not be removed from the keychain."
            case .signing(let detail):
                return "The identity key could not sign that: \(detail)"
            }
        }
    }

    private init(secIdentity: SecIdentity, certificateDER: Data, publicKeyBytes: Data, commonName: String) {
        self.secIdentity = secIdentity
        self.certificateDER = certificateDER
        self.publicKeyBytes = publicKeyBytes
        self.commonName = commonName
    }

    /// Signs a message with this identity's private key: ECDSA over P-256 with SHA-256, DER.
    ///
    /// The key does not leave the keychain to do this, so the private material never exists in this
    /// process's memory.
    ///
    /// DER rather than the fixed 64-byte form, because that is what the algorithm identifier says and
    /// what the relay's verifier expects. `.ecdsaSignatureMessageX962SHA256` hashes the message.
    public func signature(for message: Data) throws -> Data {
        var key: SecKey?
        let status = SecIdentityCopyPrivateKey(secIdentity, &key)
        guard status == errSecSuccess, let key else { throw Failure.keychain(status) }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) else {
            let detail = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "the security framework gave no reason"
            throw Failure.signing(detail)
        }
        return signature as Data
    }

    /// Loads the persistent key for `role`, generating it on first run, and mints a fresh certificate
    /// over it.
    ///
    /// - Parameter keyTag: overrides the tag derived from `role`. Supply one to keep several
    ///   independent identities on the same machine, a test client alongside the real one. The tag is
    ///   part of the keychain ACL, so reusing another identity's tag from a differently signed process
    ///   is denied by the system rather than silently shared.
    public static func loadOrCreate(
        role: Role,
        commonName: String,
        keyTag: Data? = nil
    ) throws -> SelfSignedIdentity {
        let secKey = try loadOrCreateKey(tag: keyTag ?? role.keyTag)

        let privateKey: Certificate.PrivateKey
        do {
            privateKey = try Certificate.PrivateKey(secKey)
        } catch {
            throw Failure.certificateBuild("\(error)")
        }

        let certificate: Certificate
        do {
            certificate = try makeSelfSignedCertificate(
                privateKey: privateKey,
                commonName: commonName,
                extendedKeyUsage: try role.extendedKeyUsage
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.certificateBuild("\(error)")
        }

        let der: Data
        do {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            der = Data(serializer.serializedBytes)
        } catch {
            throw Failure.certificateSerialization("\(error)")
        }

        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Failure.certificateRejected
        }
        guard let identity = SecIdentityCreate(nil, secCertificate, secKey) else {
            throw Failure.identityCreationFailed
        }

        return SelfSignedIdentity(
            secIdentity: identity,
            certificateDER: der,
            publicKeyBytes: Data(certificate.publicKey.subjectPublicKeyInfoBytes),
            commonName: commonName
        )
    }

    /// Destroys the key for `role`. Every peer that pinned it must re-pair, which is what "reset
    /// identity" should mean, hence a separate, explicit call.
    ///
    /// Deleting is a loop, not a single call: a permanent EC key is stored as two keychain items
    /// sharing one application tag, and `SecItemDelete` removes one per call while reporting success,
    /// so a single call would leave the private key for the next `loadOrCreate` to find.
    public static func destroy(role: Role, keyTag: Data? = nil) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag ?? role.keyTag,
        ]

        // Bounded because the exit condition is a status code, and a delete that neither
        // succeeds nor reports not-found would otherwise spin forever.
        for _ in 0..<8 {
            let status = SecItemDelete(SecretStore.attributes(query))
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }

        // Items are still there after repeated deletes. Saying so beats reporting a reset that did
        // not happen, since the caller's next step depends on it having worked.
        throw Failure.identityNotRemoved
    }

    private static func loadOrCreateKey(tag: Data) throws -> SecKey {
        // `kSecAttrKeyClassPrivate` is load-bearing: a permanent EC key is stored as two keychain
        // items sharing one application tag, and a query matching only on class+tag may return the
        // public half. That looks like success here and then fails inside swift-certificates with
        // "SecKey class must be 1, not 0", on the second launch only.
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(SecretStore.attributes(lookup), &item) == errSecSuccess,
           let existing = item as! SecKey? {
            return existing
        }

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard let key = SecKeyCreateRandomKey(SecretStore.attributes(attributes), &error) else {
            let detail = error.map { "\($0.takeRetainedValue())" } ?? "unknown"
            throw Failure.keyGeneration(detail)
        }
        return key
    }

    private static func makeSelfSignedCertificate(
        privateKey: Certificate.PrivateKey,
        commonName: String,
        extendedKeyUsage: ExtendedKeyUsage
    ) throws -> Certificate {
        let subject = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Peering")
        }

        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(3650 * 24 * 3600),
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                // Not a CA: this certificate signs nothing but itself.
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                extendedKeyUsage
            },
            issuerPrivateKey: privateKey
        )
    }
}
