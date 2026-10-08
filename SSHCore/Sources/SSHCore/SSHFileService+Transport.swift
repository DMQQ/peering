import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

extension SSHFileService {
    /// A type of its own because a subsystem the server will not open means this host has no SFTP, while a folder it will not read says nothing about the next; only the first is worth falling back from.
    struct SFTPUnavailable: Error {
        let reason: String
    }

    /// A session per request: Citadel's `listDirectory` never closes its directory handle, so a long-lived session leaks one server-side handle per folder viewed.
    func withSFTP<T>(_ work: (SFTPClient) async throws -> T) async throws -> T {
        let sftp: SFTPClient
        do {
            // Citadel's own logger; this module logs through `os` and the SFTP client's chatter is left on whatever the app bootstrapped.
            sftp = try await client.openSFTP()
        } catch {
            throw SFTPUnavailable(reason: Self.describe(error))
        }

        do {
            let result = try await work(sftp)
            try? await sftp.close()
            return result
        } catch {
            try? await sftp.close()
            throw error
        }
    }

    /// SFTP describes the link rather than its target, so each link gets a second look to settle whether it opens. All at once, since `/usr/bin` is a thousand round trips; a link that cannot be reached stays a file.
    static func resolvingLinks(
        _ entries: [RemoteDirectoryEntry],
        of directory: String,
        over sftp: SFTPClient
    ) async -> [RemoteDirectoryEntry] {
        let links = entries.filter(\.isSymlink).map(\.name)
        guard !links.isEmpty else { return entries }

        var targets: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for name in links {
                group.addTask {
                    let attributes = try? await sftp.getAttributes(at: childPath(name, of: directory))
                    let mode = attributes?.permissions ?? 0
                    return (name, mode & 0o170_000 == 0o040_000)
                }
            }
            for await (name, isDirectory) in group {
                targets[name] = isDirectory
            }
        }

        return entries.map { entry in
            guard entry.isSymlink, let isDirectory = targets[entry.name] else { return entry }
            return RemoteDirectoryEntry(
                name: entry.name,
                isDirectory: isDirectory,
                isSymlink: true,
                size: entry.size,
                permissions: entry.permissions,
                modified: entry.modified
            )
        }
    }

    /// `executeCommand` fails on a non-zero exit and on anything written to stderr, so an unreadable folder arrives as an error, and stderr is the sentence shown because it knows why.
    func run(_ command: String) async throws -> String {
        do {
            let buffer = try await client.executeCommand(
                command,
                maxResponseSize: Self.maximumListingBytes
            )
            return String(buffer: buffer)
        } catch let error as TTYSTDError {
            let reason = String(buffer: error.message).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHSessionError.browse(
                reason.isEmpty ? "The server refused to list that folder." : reason
            )
        } catch {
            throw SSHSessionError.browse(Self.describe(error))
        }
    }

    /// The same bounds as the Mac's browser. The listing cap is here so the limit on what this end buffers is its own decision.
    static let maximumListingBytes = 4 * 1024 * 1024

    static let maximumPreviewBytes = 128 * 1024

    /// Sixty-four times the text cap: a photograph cut partway through is no picture at all.
    static let maximumImagePreviewBytes = 8 * 1024 * 1024

    static let previewChunkBytes = 32 * 1024

    static let binaryProbeBytes = RemoteFileKind.probeBytes

    /// The two SFTP statuses with an actionable answer are a missing folder and one the user may not open; everything else uses the server's words.
    static func describe(_ error: any Error) -> String {
        switch error {
        case is SFTPUnavailable:
            // A listing never reaches here, since a session that will not open falls back to a command; a preview does, because it has nothing to fall back to.
            return "This server does not offer SFTP, so a file cannot be read here."
        case let error as SFTPError:
            switch error {
            case .errorStatus(let status):
                switch status.errorCode {
                case .noSuchFile: return "That is no longer there."
                case .permissionDenied: return "The server would not let this account read that."
                default: return status.message.isEmpty ? "The server refused." : status.message
                }
            case .missingResponse:
                return "The server did not answer."
            case .unsupportedVersion:
                return "This server speaks a version of SFTP this app does not."
            default:
                return "The folder could not be read."
            }
        case let failure as SSHClient.CommandFailed:
            return "The server refused to list that folder (status \(failure.exitCode))."
        case CitadelError.commandOutputTooLarge:
            return "That folder has more in it than this app will read at once."
        case CitadelError.channelCreationFailed, CitadelError.channelFailure:
            return "The server would not open another channel."
        default:
            return error.localizedDescription
        }
    }
}
