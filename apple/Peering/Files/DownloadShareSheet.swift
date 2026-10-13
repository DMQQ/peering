import SwiftUI
import UIKit

/// Hands a finished download to the system share sheet, where "Save to Files" puts it on this phone.
private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct DownloadShareSheet: ViewModifier {
    @Environment(SessionModel.self) private var model
    let sessionID: UUID

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.finishedDownload(sessionID: sessionID).map(ShareItem.init) },
            set: { if $0 == nil { model.clearFinishedDownload(sessionID: sessionID) } }
        )) { item in
            ActivityView(url: item.url)
                .presentationDetents([.medium, .large])
        }
    }
}

extension View {
    /// Presents the share sheet when a download for this browser finishes.
    func downloadShareSheet(sessionID: UUID) -> some View {
        modifier(DownloadShareSheet(sessionID: sessionID))
    }
}
