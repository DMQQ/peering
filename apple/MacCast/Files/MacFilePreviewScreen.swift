import RemoteCore
import SwiftUI

/// A file opened from the Mac's folders, as a page of its own so the system back button is the way out. Leaving it drops the preview the model holds.
struct MacFilePreviewScreen: View {
    let path: String

    @Environment(SessionModel.self) private var model

    private func modified(_ id: UUID) -> Date? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return model.directory(folder.isEmpty ? "/" : folder, sessionID: id)?.entries.first { $0.name == name }?.modified
    }

    var body: some View {
        Group {
            if let id = model.browserID, let preview = model.filePreview, preview.terminalID == id, preview.path == path {
                FilePreviewPanel(
                    preview: preview,
                    failure: model.browseFailure(preview.path, sessionID: id),
                    isSaving: model.isWritingFile(sessionID: id),
                    saveFailure: model.saveFailure(sessionID: id),
                    onRevealPath: nil,
                    usesToolbars: true,
                    modified: modified(id),
                    onSave: { model.saveFile($0, sessionID: id) }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ColorPalette.backdrop)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // The scope first, as the folder page does: the Mac keeps one only for the connection that made it, so after a reconnect a read sent without it is never answered.
        // A read that has not finished after a few seconds is asked for again, up to twice, since a lost request looks exactly like a slow one.
        .task(id: path) {
            guard let id = model.browserID else { return }
            for _ in 0..<3 {
                model.openFileScope()
                model.previewFile(path, sessionID: id)
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { return }
                guard let preview = model.filePreview, preview.path == path, !preview.isComplete,
                      model.browseFailure(path, sessionID: id) == nil
                else { return }
            }
        }
        .onDisappear { model.closePreview() }
    }
}
