import MacCastKit
import RemoteCore
import SwiftUI

/// The Mac's folders with no shell: the same browser as the terminal's, on a browsing scope. No shell keys or Run button, since there is no shell.
struct MacFilesScreen: View {
    @Environment(SessionModel.self) var model

    @State var showsHiddenFiles = false
    @State private var restoredPath: String?

    var body: some View {
        Group {
            if let id = model.browserID {
                content(id)
            } else {
                Text("Not connected to a Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            guard let id = model.browserID else { return }
            // The scope first: the Mac keeps one only for the connection that made it, and the listing that follows travels after it on the same connection.
            model.openFileScope()
            if model.browserPath == nil, let saved = model.rememberedFilesFolder {
                restoredPath = saved
                model.setBrowserPath(saved)
            }
            model.listDirectory(model.browserPath, sessionID: id)
        }
        // A remembered folder that is gone, renamed or no longer readable falls back to the home folder instead of leaving the browser on an error.
        .onChange(of: restoredFailure) { _, failure in
            guard failure != nil, let id = model.browserID else { return }
            restoredPath = nil
            model.forgetFilesFolder()
            model.setBrowserPath(nil)
            model.listDirectory(nil, sessionID: id)
        }
    }

    private var restoredFailure: String? {
        guard let id = model.browserID, let restoredPath, model.browserPath == restoredPath else { return nil }
        return model.browseFailure(restoredPath, sessionID: id)
    }

    @ViewBuilder
    private func content(_ id: UUID) -> some View {
        VStack(spacing: 0) {
            if let preview = model.filePreview, preview.terminalID == id {
                FilePreviewPanel(
                    preview: preview,
                    failure: model.browseFailure(preview.path, sessionID: id),
                    isSaving: model.isWritingFile(sessionID: id),
                    saveFailure: model.saveFailure(sessionID: id),
                    onRevealPath: nil,
                    onClose: { model.closePreview() },
                    onSave: { model.saveFile($0, sessionID: id) }
                    // Reading and editing stay free; the panel gates the share button (``PlanCapability/fileTransfer``).
                )
            } else {
                FileBrowserPanel(
                    path: model.browserPath,
                    directory: model.directory(model.browserPath, sessionID: id),
                    isLoading: model.isLoadingDirectory(model.browserPath, sessionID: id),
                    failure: model.uploadFailure(sessionID: id)
                        ?? model.browseFailure(model.browserPath, sessionID: id),
                    showsHidden: showsHiddenFiles,
                    // The Mac blocks inside the listing call while macOS shows a Files-and-Folders prompt, and nothing of that reaches this phone, so the wait says what it is probably waiting for.
                    waitingHint: String(localized: "If your Mac is asking whether Peering may read this folder, answer it there."),
                    progress: model.folderProgress(sessionID: id),
                    onOpen: { open($0, in: id) },
                    onNavigate: { navigate(to: $0, in: id) },
                    onRevealPath: nil,
                    onReload: { model.listDirectory(model.browserPath, sessionID: id) },
                    onUpload: { model.uploadFile($0, sessionID: id) },
                    onUploadItems: { model.uploadItems($0, sessionID: id) },
                    onRun: nil,
                    deleteHint: String(localized: "It can be put back from the Trash on your Mac."),
                    onCreate: canMake
                        ? { model.createEntry($0, kind: $1, in: folder, sessionID: id) }
                        : nil,
                    onRename: canMake
                        ? { model.renameEntry($0, to: $1, in: folder, sessionID: id) }
                        : nil,
                    onDelete: canMake
                        ? { model.deleteEntry($0, in: folder, sessionID: id) }
                        : nil,
                    isChanging: model.isChangingFile(sessionID: id),
                    changeFailure: model.changeFailure(sessionID: id)
                )
            }
            FileBrowseBar(
                isEnabled: true,
                showsHidden: showsHiddenFiles,
                showsKeys: false,
                onInterrupt: {},
                onEscape: {},
                onTab: {},
                onReload: { model.listDirectory(model.browserPath, sessionID: id) },
                onToggleHidden: { showsHiddenFiles.toggle() }
            )
        }
    }

    private var canMake: Bool { model.browserPath != nil }

    private var folder: String { model.browserPath ?? "" }

    private func open(_ entry: RemoteDirectoryEntry, in id: UUID) {
        let path = childPath(entry.name, of: model.browserPath)
        if entry.isDirectory {
            navigate(to: path, in: id)
        } else {
            model.previewFile(path, sessionID: id)
        }
    }

    private func navigate(to path: String, in id: UUID) {
        model.setBrowserPath(path)
        model.listDirectory(path, sessionID: id)
    }
}
