import Foundation
import Testing

@testable import SSHCore

/// Keys made by `ssh-keygen`, kept here as text.
///
/// Fixtures rather than keys generated inside the test, and for the reason the whole feature turns
/// on: ``SSHKeyPair`` claims the line it produces is byte-for-byte the line the server already
/// knows about, and the only way to check a claim like that is against an implementation that is
/// not this one. Every `.pub` compared against below was written by `ssh-keygen` itself, so these
/// assertions measure this app's reading of a key against OpenSSH's.
///
/// These are throwaway keys for machines that do not exist. Nothing is ever signed with them.
///
/// Shared with the credential-store suite, which needs a real key to prove that a `.key` survives
/// the same round trip a password does.
enum KeyFixture {
    /// ed25519, no passphrase, comment `nolabel`.
    static let plainPrivate = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCLr67D5384+tFrsKkkFRxY+OWDlgRtIYarMRqGtk6F4gAAAJD15MVA9eTF
        QAAAAAtzc2gtZWQyNTUxOQAAACCLr67D5384+tFrsKkkFRxY+OWDlgRtIYarMRqGtk6F4g
        AAAEB/qqNUrYybtbOtMfxN5AnLfnLSv7zU1+5FNbLX6U3/dYuvrsPnfzj60WuwqSQVHFj4
        5YOWBG0hhqsxGoa2ToXiAAAAB25vbGFiZWwBAgMEBQY=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let plainPublic =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuvrsPnfzj60WuwqSQVHFj45YOWBG0hhqsxGoa2ToXi nolabel"

    /// The same shape with a passphrase. The space in it is deliberate: a passphrase is bytes, and
    /// trimming or splitting one would be a bug that only shows up for people whose passphrase is
    /// a sentence.
    static let protectedPassphrase = "correct horse"
    static let protectedPrivate = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCcg4CsvA
        TKcX6nnKhS8EWcAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAICgGzVdkMRBdzw6K
        Bh0QJMDRCkJLsWMu6y+EOVjy+5iJAAAAkGLHr2vHhr96qQPfJsablKMWM/IhWagak98Fvl
        q6g8TcK7JxIkFcCBoodO/LcbD9eLQbPhWQU1BZWXutHEcWUz42w+gpEK0lMs55i5J6vMz3
        sVc/DK8dm9nhT6jWEFSjQuKtHQ2A22NrNRAR4PKaB9ssgx6DdKzsECQ2UV3Hvt7Qn3X553
        i1XCZd/l6oOFAJow==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let protectedPublic =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICgGzVdkMRBdzw6KBh0QJMDRCkJLsWMu6y+EOVjy+5iJ phone@test"

    /// RSA, no passphrase: the one algorithm besides ed25519 this app can sign with.
    static let rsaPrivate = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQEA0d5DyBLGXADwZlTGLdvOoqorBoZDVxZHTnFYDHer3OooN2O2VBFB
        35x4Ozt97wMCO2744Am1t6VJrRBkuaqXFnvrNDBhZH0Z5BzBQyX4MiaJX/MrKSfl9o87AJ
        78erh+2JxWxsvTW+YVrM9LzzmRFuoO35Cvs7MUUaSbV38r9CGGGAJGjxCcrHvQH1yH3WxP
        SXs2AT2i8eO4tb89voCNr5J+bX3H+kuYo9qV1rBVO2GacFHhrYkPvXUd54LtZj+z/be/wt
        s7Rplpu1SfrEKDsxVGE+dXVfRnTBsgCNpVhwhyHWWF3K3O6z3PQbKdMq4BslQgucnegYJh
        RFXKBCED0QAAA8AkHHG0JBxxtAAAAAdzc2gtcnNhAAABAQDR3kPIEsZcAPBmVMYt286iqi
        sGhkNXFkdOcVgMd6vc6ig3Y7ZUEUHfnHg7O33vAwI7bvjgCbW3pUmtEGS5qpcWe+s0MGFk
        fRnkHMFDJfgyJolf8yspJ+X2jzsAnvx6uH7YnFbGy9Nb5hWsz0vPOZEW6g7fkK+zsxRRpJ
        tXfyv0IYYYAkaPEJyse9AfXIfdbE9JezYBPaLx47i1vz2+gI2vkn5tfcf6S5ij2pXWsFU7
        YZpwUeGtiQ+9dR3ngu1mP7P9t7/C2ztGmWm7VJ+sQoOzFUYT51dV9GdMGyAI2lWHCHIdZY
        Xcrc7rPc9Bsp0yrgGyVCC5yd6BgmFEVcoEIQPRAAAAAwEAAQAAAQEAoC2oRjguNWJyGWhy
        qeWuXPDMTfqDwyA55GEV9s4P2ljNwRjVvGw/ftAJ5AuQHrCJL5uPUE+Y5kW9ad2tQxg0oP
        CLoBWc//mLnVNlHj8IpB5Nk3IhaxQMrJa9TcgKpA/UoLcSdEB1XRrLSE4falZhqr+SAoiH
        0fvIclfUSH/DqFvbliPHWKAhHY+4z/iY2tJ3UleWdkuyVwZIGuv/ZHJMpzoH8ck5HWbWB4
        ++mViUUnBnNP3dLjLjQYlu8NKGopRLEBjlsP4C9ZKJ630Gbtx8g/i4pLz3oSL25MuK9ENt
        3duaVTOwT+7iGwqCi3r0z7MuxPR9+4oN6R8PyCtzJ7LMUQAAAIEAy+tf/wnw4TEtIl1RYc
        VVstJJWqVg672IO1g5K8eBSQrHzbOHnozpqETJLYGrM/TLlj0AhLnW+EV5oN8ooj3u0HqH
        x4oxBqeoWe5XYC+5wEV6Na8CdTjyelSKqxS1Whl1HJlRksV/c9jUu7hGqWIyt8VnmlY5ME
        /osAMN4TGgQ1AAAACBAPQFANlyVA6o5U7vfIezs6689e1kEvs6aeGACXJyyTOOBeeRqu2Z
        ynZzaxHpaay40uYJWrGqOEJuacHYm1S02q1bkSUk8I6uELkgvdiCMKNoctGx94aHzDXIL3
        qtrOksqjt+s+0vmczenXsGUjNn4TQe+RTZgtzAdU6uZEgYuZBDAAAAgQDcLAZ+4TUK/Ftp
        LNaEmRye9+vdIJWoddHVPQSehYpZcpqTZl7yf/MKp6JGPV2uNMgEcJoxhw0n2nlvIFwQOO
        HvvnFrVni6dRbuO+7GxqTONmwuQlctCl8uOHgqbIZ8NkoG9RhLtDoYegEHncGnIfLTt2kI
        uSfSJBF4K7gWZ+yUWwAAAAZsZWdhY3kBAgM=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let rsaPublic =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDR3kPIEsZcAPBmVMYt286iqisGhkNXFkdOcVgMd6vc6ig3Y7ZUEUHfnHg7O33vAwI7bvjgCbW3pUmtEGS5qpcWe+s0MGFkfRnkHMFDJfgyJolf8yspJ+X2jzsAnvx6uH7YnFbGy9Nb5hWsz0vPOZEW6g7fkK+zsxRRpJtXfyv0IYYYAkaPEJyse9AfXIfdbE9JezYBPaLx47i1vz2+gI2vkn5tfcf6S5ij2pXWsFU7YZpwUeGtiQ+9dR3ngu1mP7P9t7/C2ztGmWm7VJ+sQoOzFUYT51dV9GdMGyAI2lWHCHIdZYXcrc7rPc9Bsp0yrgGyVCC5yd6BgmFEVcoEIQPR legacy"

    /// `ssh-keygen -a 40`: well-formed, and past what Citadel's KDF parser will accept.
    static let costlyPrivate = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAVoUXlVy
        GPMuVeJ6D5DlDYAAAAKAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINunv4MpuALUmeoH
        7mNJNtyWiFv+OzFkEOAwpYoFju9sAAAAkHyyf4TIrJq9dNX170MBZlqEeg/5HkqD8dmdDa
        TXAhmabivlasDB+7gDKPEKSyTfmVVgO0yGYcYZGp9VVCGHwvFExSVoO462JBhS4YuBLTPf
        7jc2z0UWDNDl45to0OGXkBAZYg4bv5nav5tZcv/KMkTK7jBsGFnO7eXgMYiHm6jUZNywIY
        ASsmzWQZwYCdsVWw==
        -----END OPENSSH PRIVATE KEY-----
        """

    /// `ssh-keygen -Z aes256-gcm@openssh.com`: a cipher the library has no case for.
    static let gcmPrivate = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAAFmFlczI1Ni1nY21Ab3BlbnNzaC5jb20AAAAGYmNyeXB0AA
        AAGAAAABCFJHh4O+np3O/lLuJ9CIQdAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAA
        ILO5ydtYqIsuRpWzBa+bsxw4oTNTGlVA+64KwthtcHqjAAAAkImy9WypPPclV4YLZ4RgI2
        lVod0yTZoGpZ0Vr2TDTL/Rb9c1J99l86acIJTbINNCcqJ4xopJjVaswvjddxaWSZoUNjpV
        W5fknvkzt0E5o2CbtNC5fFz9XVFwl4odUuiTH46MennFB2nPiGYDLOCxuo2JBW6jquvCnT
        glv4m+TjZht0LjvoEW08E5kuvbxUfcv60v5+arq8AGNrBdDIGvXTI=
        -----END OPENSSH PRIVATE KEY-----
        """

    /// An ECDSA key: readable, well-formed, and not something this app can sign with.
    static let ecdsaPrivate = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTjWd7BP4sIxm2+HrxlKCXJXkpS3Q/z
        tVLZ7Z0/VZuGT98dxGRkfiSlTku1Q+UZPZz3+gN7tePtpj5SwoOxh6e3AAAAoFYnnA1WJ5
        wNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBONZ3sE/iwjGbb4e
        vGUoJcleSlLdD/O1UtntnT9Vm4ZP3x3EZGR+JKVOS7VD5Rk9nPf6A3u14+2mPlLCg7GHp7
        cAAAAhAPga4eOhQUZfgx8DJB9A6vHjQGr/Z/aRKlsSFBU8Oi+GAAAABWN1cnZlAQI=
        -----END OPENSSH PRIVATE KEY-----
        """
}

@Suite("Keys")
struct SSHKeyTests {
    @Test("a key made by ssh-keygen reads back to the public line ssh-keygen wrote")
    func importedPublicLineMatchesOpenSSH() throws {
        let ed25519 = try SSHKeyPair.imported(KeyFixture.plainPrivate, passphrase: nil)
        #expect(ed25519.publicKey == KeyFixture.plainPublic)

        let rsa = try SSHKeyPair.imported(KeyFixture.rsaPrivate, passphrase: nil)
        #expect(rsa.publicKey == KeyFixture.rsaPublic)
    }

    @Test("a generated key's public line is the same line when it is read back")
    func generatedPublicLineIsStable() throws {
        let made = try SSHKeyPair.generate(comment: "box.example.com")
        let readBack = try SSHKeyPair.imported(made.privateKey, passphrase: nil)

        #expect(readBack.publicKey == made.publicKey)
        #expect(made.algorithm == "ssh-ed25519")
        #expect(made.comment == "box.example.com")
    }

    @Test("a generated key has no passphrase, and says so")
    func generatedKeyIsUnlocked() throws {
        let made = try SSHKeyPair.generate()
        #expect(made.passphrase == nil)
        #expect(made.publicKey.split(separator: " ").count == 2)
    }

    @Test("two generated keys are two keys")
    func generatedKeysDiffer() throws {
        let first = try SSHKeyPair.generate()
        let second = try SSHKeyPair.generate()
        #expect(first.publicKey != second.publicKey)
    }

    @Test("the algorithm and the comment come off the public line")
    func algorithmAndComment() throws {
        let key = try SSHKeyPair.imported(KeyFixture.plainPrivate, passphrase: nil)
        #expect(key.algorithm == "ssh-ed25519")
        #expect(key.comment == "nolabel")

        let rsa = try SSHKeyPair.imported(KeyFixture.rsaPrivate, passphrase: nil)
        #expect(rsa.algorithm == "ssh-rsa")
        #expect(rsa.comment == "legacy")
    }

    @Test("relabelling keeps the key and changes only the trailing name")
    func relabelling() throws {
        let key = try SSHKeyPair.imported(KeyFixture.plainPrivate, passphrase: nil)
        let renamed = key.labelled("damian@iphone")
        let blob = KeyFixture.plainPublic.split(separator: " ")[1]

        #expect(renamed.publicKey == "ssh-ed25519 \(blob) damian@iphone")
        #expect(renamed.comment == "damian@iphone")
        #expect(renamed.algorithm == "ssh-ed25519")
        #expect(renamed.privateKey == key.privateKey)
    }

    @Test("a comment with a space in it survives being written and read")
    func commentWithSpace() throws {
        let key = try SSHKeyPair.imported(KeyFixture.plainPrivate, passphrase: nil).labelled("iphone 17 pro")
        #expect(key.comment == "iphone 17 pro")
        #expect(key.algorithm == "ssh-ed25519")
    }

    @Test("an empty label leaves a line of two fields, not a trailing space")
    func emptyLabel() throws {
        let key = try SSHKeyPair.imported(KeyFixture.plainPrivate, passphrase: nil).labelled("")
        #expect(key.publicKey.split(separator: " ").count == 2)
        #expect(key.comment == "")
    }

    @Test("a passphrase-protected key opens with its passphrase and not without one")
    func passphrase() throws {
        let opened = try SSHKeyPair.imported(KeyFixture.protectedPrivate, passphrase: KeyFixture.protectedPassphrase)
        // The key half matches ssh-keygen's line exactly; the label does not, because the comment
        // sits behind the encryption and reading it would mean implementing aes-ctr and bcrypt here.
        // The line is still a valid `authorized_keys` entry without one, and the editor offers a
        // label of its own, so this is a cosmetic gap rather than one that leaves a key unusable.
        #expect(opened.publicKey == KeyFixture.protectedPublic.replacingOccurrences(of: " phone@test", with: ""))
        #expect(opened.comment == "")
        #expect(opened.algorithm == "ssh-ed25519")
        #expect(opened.passphrase == KeyFixture.protectedPassphrase)

        #expect(throws: SSHKeyError.passphraseNeeded) {
            try SSHKeyPair.imported(KeyFixture.protectedPrivate, passphrase: nil)
        }
        #expect(throws: SSHKeyError.passphraseWrong) {
            try SSHKeyPair.imported(KeyFixture.protectedPrivate, passphrase: "not it")
        }
    }

    @Test("an unencrypted key drops a passphrase rather than storing a useless one")
    func passphraseOnAPlainKey() throws {
        let key = try SSHKeyPair.imported(KeyFixture.plainPrivate, passphrase: "hoping")
        #expect(key.passphrase == nil)
    }

    @Test("the two formats the library cannot open are refused by name, at the point of pasting")
    func unreadableFormats() {
        #expect(throws: SSHKeyError.self) {
            try SSHKeyPair.imported(KeyFixture.costlyPrivate, passphrase: "x")
        }
        #expect(throws: SSHKeyError.self) {
            try SSHKeyPair.imported(KeyFixture.gcmPrivate, passphrase: "x")
        }
    }

    @Test("the refusal names the cipher or the cost, so the fix is in the message")
    func unreadableFormatMessages() {
        do {
            _ = try SSHKeyPair.imported(KeyFixture.gcmPrivate, passphrase: "x")
            Issue.record("a gcm-encrypted key was accepted")
        } catch let error as SSHKeyError {
            guard case .unsupportedFormat(let detail) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(detail.contains("aes256-gcm@openssh.com"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        do {
            _ = try SSHKeyPair.imported(KeyFixture.costlyPrivate, passphrase: "x")
            Issue.record("a 40-round key was accepted")
        } catch let error as SSHKeyError {
            guard case .unsupportedFormat(let detail) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(detail.contains("40"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("a public key pasted where the private one goes is refused in those words")
    func publicKeyPasted() {
        #expect(throws: SSHKeyError.notAPrivateKey) {
            try SSHKeyPair.imported(KeyFixture.plainPublic, passphrase: nil)
        }
        #expect(SSHKeyError.notAPrivateKey.message.contains("public half"))
    }

    @Test("text that is not a key at all is refused rather than half-read")
    func junk() {
        #expect(throws: SSHKeyError.notAPrivateKey) {
            try SSHKeyPair.imported("hello", passphrase: nil)
        }
        #expect(throws: SSHKeyError.malformed("the body is not valid base64")) {
            try SSHKeyPair.imported(
                "-----BEGIN OPENSSH PRIVATE KEY-----\nnot base64 at all!!\n-----END OPENSSH PRIVATE KEY-----",
                passphrase: nil
            )
        }
    }

    @Test("a truncated key is an error and not a crash")
    func truncated() {
        // Cut in the middle of the base64 body, which is where a clipboard loses bytes.
        #expect(throws: SSHKeyError.self) {
            try SSHKeyPair.imported(String(KeyFixture.plainPrivate.dropLast(40)), passphrase: nil)
        }
    }

    @Test("an ECDSA key is refused by name rather than accepted and unusable")
    func ecdsa() {
        #expect(throws: SSHKeyError.unsupportedAlgorithm("ecdsa-sha2-nistp256")) {
            try SSHKeyPair.imported(KeyFixture.ecdsaPrivate, passphrase: nil)
        }
        #expect(SSHKeyError.unsupportedAlgorithm("ecdsa-sha2-nistp256").message.contains("ed25519 and RSA"))
    }

    @Test("a key survives the round trip through storage")
    func codableRoundTrip() throws {
        let key = try SSHKeyPair.imported(KeyFixture.protectedPrivate, passphrase: KeyFixture.protectedPassphrase)
        let encoded = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(SSHKeyPair.self, from: encoded) == key)
    }
}
