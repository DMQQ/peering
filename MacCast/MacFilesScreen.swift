import MacCastKit
import RemoteCore
import SwiftUI

/// The Mac's folders, with no shell behind them.
///
/// The same browser the terminal shows instead of its output — same panel, same rows, same
/// previews — hung on a browsing scope rather than a terminal, which is what lets it be opened
/// on its own from the hub. What it does not have is the three shell keys and the Run button:
/// there is no shell to type into or launch from here, and a control that answers nothing is
/// worse than one that was never offered.
struct MacFilesScreen: View {
    @Environment(SessionModel.self) var model

    @State var showsHiddenFiles = false

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
            // The scope first: the Mac keeps one only for the connection that made it, and it
            // takes the same id again without complaint. The listing that follows travels after
            // it on the same connection, so the scope exists by the time it is answered.
            model.openFileScope()
            model.listDirectory(model.browserPath, sessionID: id)
        }
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
                    // Reading and editing a file stay free; handing it to the phone does not, and
                    // the panel gates the share button itself. See
                    // ``PlanCapability/fileTransfer``.
                )
            } else {
                FileBrowserPanel(
                    path: model.browserPath,
                    directory: model.directory(model.browserPath, sessionID: id),
                    isLoading: model.isLoadingDirectory(model.browserPath, sessionID: id),
                    // An upload that failed shares the slot, as it does on the other browsers: it
                    // is a fact about this folder, and the next attempt clears it.
                    failure: model.uploadFailure(sessionID: id)
                        ?? model.browseFailure(model.browserPath, sessionID: id),
                    showsHidden: showsHiddenFiles,
                    // The Mac blocks inside the listing call while macOS puts a Files-and-Folders
                    // question on its screen, and nothing about that reaches this phone: the
                    // request is simply outstanding, so the wait says what it is probably waiting
                    // for and where the answer is.
                    waitingHint: String(localized: "If your Mac is asking whether Peering may read this folder, answer it there."),
                    progress: model.folderProgress(sessionID: id),
                    onOpen: { open($0, in: id) },
                    onNavigate: { navigate(to: $0, in: id) },
                    onRevealPath: nil,
                    onReload: { model.listDirectory(model.browserPath, sessionID: id) },
                    onUpload: { model.uploadFile($0, sessionID: id) },
                    onUploadItems: { model.uploadItems($0, sessionID: id) },
                    // No Run: it exists to type a command into a shell, and this browser is
                    // exactly the case where there is not one.
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

    /// Nothing to be careful about: a folder can be changed as soon as the Mac has said where this
    /// browser opens, which is the one thing that has to be known before a change can name a path.
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

    /// Into a folder. No `cd` follows, unlike the terminal's browser: there is no shell here, so
    /// looking at a folder is all this does.
    private func navigate(to path: String, in id: UUID) {
        model.setBrowserPath(path)
        model.listDirectory(path, sessionID: id)
    }
}
