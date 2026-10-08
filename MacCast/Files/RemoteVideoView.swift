import AVKit
import SwiftUI

/// A video of any size the download path moves. The preview carries only the header; the file itself is fetched by range to a temporary file, since AVPlayer reads files and a video held in memory is a termination.
struct RemoteVideoView: View {
    let path: String
    let sessionID: UUID
    let totalBytes: Int

    @Environment(SessionModel.self) private var model
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if let failure = model.downloadFailure(sessionID: sessionID) {
                message(failure)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: model.downloadProgress(sessionID: sessionID)
                        ?? String(localized: "Loading \(totalBytes.formatted(.byteCount(style: .file)))…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            model.downloadFile(path, sessionID: sessionID, playsInline: true)
        }
        .onChange(of: model.finishedVideo(path, sessionID: sessionID)) { _, url in
            if let url { player = AVPlayer(url: url) }
        }
        .onDisappear {
            player?.pause()
            if player == nil { model.cancelDownload(sessionID: sessionID) }
        }
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
