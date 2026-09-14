import Foundation
import Security
import SwiftASN1
import X509

/// A long-term TLS identity: a keychain-backed P-256 key with a self-signed certificate
/// minted over it at launch. Used by both the host and the client.
///
/// The private key never leaves the keychain. `Certificate.PrivateKey(secKey)` signs
/// through `SecKeyCreateSignature` rather than exporting the key material, so there is no
/// window in which the private bytes exist in process memory — and the key is eligible for
/// Secure Enclave backing.
///
/// **The certificate is regenerated on every launch, on purpose.** Peers pin the public
/// *key*, not the certificate, so a fresh serial number and validity window change nothing
/// about the pin. Regenerating costs one ECDSA signature and removes an entire class of
/// "my certificate expired and now nothing connects" failures. This is precisely the
/// reason the design chose SPKI pinning over leaf-certificate pinning.
///
/// `kSecAttrIsPermanent: true` is load-bearing, not tidiness: `SecIdentityCreate` requires
/// a keychain-backed key and returns nil for an ephemeral one. That was the single
/// genuinely unverified step in the plan, and the Phase 0a spike proved it works.
public final class SelfSignedIdentity: @unchecked Sendable {
    /// Which side of the connection this identity represents.
    ///
    /// The two roles differ only in the keychain tag and the extended key usage — enough
    /// that a machine running both (a Mac hosting and also acting as a client) keeps two
    /// distinct keys rather than one that confuses the two.
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
    /// This is the pin value. It is byte-identical to what `SecKeyCopyExternalRepresentation`
    /// returns for the same key, which is what lets either side verify a pin with no ASN.1
    /// library at all.
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
                return "SecIdentityCreate failed — the key may not be keychain-backed."
            case .identityNotRemoved:
                return "The identity key could not be removed from the keychain."
            }
        }
    }

    private init(secIdentity: SecIdentity, certificateDER: Data, publicKeyBytes: Data, commonName: String) {
        self.secIdentity = secIdentity
        self.certificateDER = certificateDER
        self.publicKeyBytes = publicKeyBytes
        self.commonName = commonName
    }

    /// Loads the persistent key for `role`, generating it on first run, and mints a
    /// fresh certificate over it.
    ///
    /// - Parameter keyTag: overrides the tag derived from `role`. Supply one to keep
    ///   several independent identities on the same machine — a test client alongside the
    ///   real one, or a profile that can be reset without disturbing the others. The tag is
    ///   part of the keychain ACL, so reusing another identity's tag from a differently
    ///   signed process is denied by the system rather than silently shared.
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

    /// Destroys the key for `role`. Every peer that pinned it must re-pair, which is
    /// exactly what "reset identity" should mean — hence it is a separate, explicit call.
    ///
    /// Deleting is a loop, not a single call, and that is not defensive padding: a
    /// permanent EC key is stored as *two* keychain items sharing one application tag, and
    /// `SecItemDelete` removes one of them per call **while reporting success**. A single
    /// call therefore leaves the private key in place, the next `loadOrCreate` finds it,
    /// and "reset identity" silently keeps the identity it claimed to destroy. Verified
    /// against the real keychain, not assumed.
    public static func destroy(role: Role, keyTag: Data? = nil) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag ?? role.keyTag,
        ]

        // Bounded because the exit condition is a status code, and a delete that neither
        // succeeds nor reports not-found would otherwise spin forever.
        for _ in 0..<8 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }

        // Items are still there after repeated deletes. Saying so beats reporting a reset
        // that did not happen — the caller's next step depends on it having worked.
        throw Failure.identityNotRemoved
    }

    private static func loadOrCreateKey(tag: Data) throws -> SecKey {
        // `kSecAttrKeyClassPrivate` is load-bearing. A permanent EC key is stored as two
        // keychain items — the private key and its public half — sharing one application
        // tag, and a query that matches only on class+tag may return either. Returning the
        // public key looks like success here and then fails deep inside
        // swift-certificates with "SecKey class must be 1, not 0", on the second launch
        // only, because the first launch creates the key and never queries for it.
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
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
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
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
