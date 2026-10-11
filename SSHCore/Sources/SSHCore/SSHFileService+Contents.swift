import Citadel
import Foundation
import NIO
import NIOFoundationCompat
import RemoteCore
import os

extension SSHFileService {
    /// SFTP only: a safe preview needs a `stat` before the bytes (follow links, regular file, capped read). The fallback would read first, and a read of a fifo or device never returns, wedging the command loop every keystroke goes through.
    func contents(at path: String) async throws -> SSHFileContents {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so a file cannot be read here."
            )
        }

        return try await withSFTP { sftp in
            // `getAttributes` is SSH_FXP_STAT and follows a symbolic link, as the Mac's browser does.
            let attributes = try await sftp.getAttributes(at: path)
            // A folder, fifo, socket or device is an error or a wait, so the type is settled before opening; a response that does not say counts as not a file.
            guard let mode = attributes.permissions, mode & 0o170_000 == 0o100_000 else {
                throw SSHSessionError.browse("That is not a file, so there is nothing to show here.")
            }

            let totalBytes = Int(clamping: attributes.size ?? 0)

            let file = try await sftp.openFile(filePath: path, flags: .read)
            var data = Data()
            var kind = RemoteFileKind.text
            var limit = Self.maximumPreviewBytes

            /// A read may return less than asked, so it is asked again. A local function because this runs twice.
            func read(upTo cap: Int) async throws {
                while data.count < cap {
                    let length = UInt32(min(cap - data.count, Self.previewChunkBytes))
                    let piece = try await file.read(from: UInt64(data.count), length: length)
                    guard piece.readableBytes > 0 else { break }
                    data.append(contentsOf: piece.readableBytesView)
                }
            }

            do {
                // Twice, because the head of the file decides how much of the rest is worth carrying.
                let probe = attributes.size == nil
                    ? Self.binaryProbeBytes
                    : min(totalBytes, Self.binaryProbeBytes)
                try await read(upTo: probe)

                guard let sniffed = RemoteFileKind.sniff(prefix: data, path: path) else {
                    throw SSHSessionError.browse(
                        "That file is not text or a picture, so there is nothing to show here."
                    )
                }
                kind = sniffed
                limit = attributes.size == nil
                    ? (kind.isDrawn ? Self.maximumImagePreviewBytes : Self.maximumPreviewBytes)
                    : min(totalBytes, kind.isDrawn
                        ? Self.maximumImagePreviewBytes
                        : Self.maximumPreviewBytes)
                try await read(upTo: limit)
                try? await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            // A server that reported no size counts as truncated once the cap is reached: truncated content must never be written back.
            let truncated = data.count >= limit
                && (attributes.size == nil || totalBytes > data.count)

            // A raster image goes as read; text and SVG have one more check, after the handle is shut so it is closed exactly once.
            if kind == .image {
                return SSHFileContents(
                    path: path,
                    data: data,
                    kind: .image,
                    totalBytes: max(totalBytes, data.count),
                    isTruncated: truncated
                )
            }
            return try Self.text(
                data,
                kind: kind,
                path: path,
                totalBytes: max(totalBytes, data.count),
                isTruncated: truncated
            )
        }
    }

    /// SFTP only: sending file contents through a shell means quoting and here-documents that could write something other than what the user meant. `write | create | truncate` replaces the whole file and keeps its mode, so a saved script stays executable.
    func write(_ contents: Data, to path: String) async throws -> SSHFileContents {
        guard provider != .exec else {
            throw SSHSessionError.browse(
                "This server does not offer SFTP, so a file cannot be saved here."
            )
        }

        return try await withSFTP { sftp in
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            )
            do {
                // `SFTPFile.write` splits into 32 KB pieces itself, so the whole buffer can be handed over.
                try await file.write(ByteBuffer(data: contents), at: 0)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            return SSHFileContents(path: path, data: contents, totalBytes: contents.count)
        }
    }
}
